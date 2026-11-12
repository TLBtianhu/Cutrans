"""Verify environment exit orchestration with real Host RPC and hidden NanoUI."""
from __future__ import annotations

import argparse
import ctypes as c
import json
import os
from pathlib import Path
import shutil
import struct
import sys
import time

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from verification_context import context_record
from verification_paths import check_root, claim, default_root, retain
from verify_host import invoke, run, state
from verify_input import hashes
from verify_jobs import JOBS_READ, OK, SMALL
from verify_jobs_async import BIG
from verify_resource_operations import configure
from verify_resource_versions import host_rpc
from verify_same_file import require
from verify_work_documents import WorkClient
from verify_workspace_rpc import Workspace, Pipe

COMMAND_RESULT = 1


def control(wire, action, expected):
    connection = Pipe(wire.endpoint)
    try:
        connection.write(f"cutrans_vm_host=1\ncommand={action}\n".encode("utf-8"))
        snapshot = state(connection.read_message(1024).decode("utf-8").replace("\n", " "))
    finally:
        connection.close()
    require(snapshot["state"] == expected, f"{action} returned {snapshot}, expected {expected}")
    return snapshot


def command(wire, name, arg, expected=OK):
    name_bytes, arg_bytes = name.encode("utf-8"), arg.encode("utf-8")
    payload = struct.pack("<II", len(name_bytes), len(arg_bytes)) + name_bytes + arg_bytes
    status, value, content = host_rpc(wire, COMMAND_RESULT, payload)
    require(status == expected, f"{name} returned status={status}, expected={expected}")
    return value


def jobs(wire):
    for _ in range(8):
        status, value, content = host_rpc(wire, JOBS_READ)
        if status == OK and value == 0:
            return json.loads(content)
        require(status == SMALL, f"jobs read failed while exiting: {status}")
    raise RuntimeError("jobs page did not stabilize while exiting")


def queue_jobs(wire, data, prefix):
    fixture = data / "fixtures/document.cut"
    fixture.parent.mkdir(parents=True, exist_ok=True)
    fixture.write_text(BIG, encoding="utf-8")
    command(wire, "doc.open", "session://fixtures/document.cut")
    return [command(wire, "editor.export.png", f"session://exports/{prefix}-{index}.png", 1)
        for index in range(3)]


def drained(wire):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        page = jobs(wire)
        if page["active_count"] == 0 and not page["record_pending"]:
            return page
        time.sleep(0.05)
    raise RuntimeError("existing jobs did not drain while new business was stopped")


def job_case(console, root, evidence, cancel):
    name = "cancel" if cancel else "wait"
    data = check_root(root / f"{name} data")
    wire = Workspace(data, evidence)
    stopped = False
    try:
        invoke(console, "start", data, "portable")
        queue_jobs(wire, data, name)
        require(jobs(wire)["active_count"] > 0, f"{name} fixture has no active jobs to exercise")
        control(wire, "prepare_stop", "stopping")
        command(wire, "editor.export.png", f"session://exports/{name}-rejected.png", 5)
        if cancel:
            control(wire, "cancel_jobs", "stopping")
        page = drained(wire)
        if cancel:
            require(any(item["state"] == "cancelled" and item["cancel_requested"] for item in page["items"]),
                "cooperative cancellation did not persist a cancelled job")
        else:
            require(all(item["state"] == "succeeded" for item in page["items"]),
                "waiting for existing jobs changed or cancelled their outcomes")
        control(wire, "stop", "stopped")
        stopped = True
        evidence["checks"].append(f"{name}_existing_jobs_while_stopping_and_new_business_rejected")
    finally:
        if not stopped:
            try:
                invoke(console, "stop", data, "portable")
            except Exception as error:
                evidence[f"{name}_cleanup_error"] = repr(error)


def resume_case(console, root, evidence):
    data = check_root(root / "resume data")
    wire = Workspace(data, evidence)
    stopped = False
    try:
        invoke(console, "start", data, "portable")
        control(wire, "prepare_stop", "stopping")
        command(wire, "editor.export.png", "session://exports/resume-rejected.png", 5)
        control(wire, "resume_work", "running")
        command(wire, "editor.invert.add", "c1")
        control(wire, "stop", "stopped")
        stopped = True
        evidence["checks"].append("resume_reopens_business_without_a_new_host")
    finally:
        if not stopped:
            try:
                invoke(console, "stop", data, "portable")
            except Exception as error:
                evidence["resume_cleanup_error"] = repr(error)


def stranded_case(console, root, evidence):
    """A Shell that left during `stopping` must not strand the next start."""
    data = check_root(root / "stranded data")
    wire = Workspace(data, evidence)
    stopped = False
    try:
        invoke(console, "start", data, "portable")
        control(wire, "prepare_stop", "stopping")
        _, current = invoke(console, "start", data, "portable")
        require(current["state"] == "running",
            "a controller start did not settle a stranded stopping Host")
        invoke(console, "stop", data, "portable")
        stopped = True
        evidence["checks"].append("controller_start_settles_a_stranded_stopping_host")
    finally:
        if not stopped:
            try:
                invoke(console, "stop", data, "portable")
            except Exception as error:
                evidence["stranded_cleanup_error"] = repr(error)


def invalid_control_case(console, root, evidence):
    """An invalid control transition must reply, not terminate the Host."""
    data = check_root(root / "invalid control data")
    wire = Workspace(data, evidence)
    stopped = False
    try:
        invoke(console, "start", data, "portable")
        control(wire, "resume_work", "running")
        _, current = invoke(console, "status", data, "portable")
        require(current["state"] == "running", "invalid resume_work killed or changed the Host")
        control(wire, "stop", "stopped")
        stopped = True
        evidence["checks"].append("invalid_control_transition_replies_and_keeps_the_host_alive")
    finally:
        if not stopped:
            try:
                invoke(console, "stop", data, "portable")
            except Exception as error:
                evidence["invalid_control_cleanup_error"] = repr(error)


def failure_case(console, root, evidence):
    data = check_root(root / "failure data")
    wire = Workspace(data, evidence)
    documents = data / "documents"
    backup = data / "documents-backup"
    stopped = False
    try:
        invoke(console, "start", data, "portable")
        control(wire, "prepare_stop", "stopping")
        if documents.exists():
            shutil.move(documents, backup)
        documents.write_text("deliberately not a directory", encoding="utf-8")
        control(wire, "stop", "degraded")
        failed_start = run([str(console), "start", "--mode=portable", f"--data={data}"], expected=1)
        require("HostNotReady" not in failed_start and "HostStopFailed" in failed_start,
            "a degraded Host was reported as not ready instead of returning its save failure")
        documents.unlink()
        if backup.exists():
            shutil.move(backup, documents)
        else:
            documents.mkdir()
        _, recovered = invoke(console, "start", data, "portable")
        require(recovered["state"] == "running" and recovered["abnormal"] == 0,
            "a controller start did not settle and replace a degraded Host after the save path recovered")
        invoke(console, "stop", data, "portable")
        stopped = True
        evidence["checks"].append("save_failure_keeps_host_degraded_until_explicit_retry_succeeds")
        evidence["checks"].append("controller_start_settles_degraded_host_after_save_path_recovers")
    finally:
        if documents.is_file():
            documents.unlink()
            if backup.exists() and not documents.exists():
                shutil.move(backup, documents)
        if not stopped:
            try:
                invoke(console, "stop", data, "portable")
            except Exception as error:
                evidence["failure_cleanup_error"] = repr(error)


def ui_case(console, root, evidence):
    data = check_root(root / "ui data")
    stopped = False
    try:
        invoke(console, "start", data, "portable")
        output = run([str(console), "--role=shell", "--mode=portable", f"--data={data}",
            f"--shell-dir={console.parent / 'payload/desktop'}", "--exit-demo"])
        require("CUTRANS_SAFE_EXIT_DRAFT_OK" in output
            and "work_revision=1" in output and "stop_retry=1" in output
            and "CUTRANS_SAFE_EXIT_OK" in output,
            "the NanoUI exit button did not preserve a draft, report a real failure and retry to a normal stop")
        require("shell_id=desktop-shell" in (data / "session/runtime.lock").read_text(encoding="utf-8"),
            "the Shell identity was not committed before the Host stopped")
        _, current = invoke(console, "status", data, "portable")
        require(current["state"] in {"stopped", "unreachable"} and current["abnormal"] == 0,
            "safe exit did not produce a normal stopped Host")
        stopped = True
        _, restarted = invoke(console, "start", data, "portable")
        require(restarted["state"] == "running" and restarted["abnormal"] == 0,
            "the environment did not restart normally after safe exit")
        invoke(console, "stop", data, "portable")
        library = c.WinDLL(str(console.parent / "runtime/cutrans_vm_runtime.dll"))
        configure(library)
        runtime = WorkClient(library, console.parent / "runtime", data, evidence)
        try:
            metadata, body = runtime.work_snapshot(1)
            require(metadata.work_revision == 1 and metadata.draft_revision > 0
                and body.decode("utf-8") == "安全退出时只保存草稿，不自动提交正文",
                "safe exit committed or lost the protected draft")
        finally:
            runtime.close()
        evidence["checks"].append("nanoui_draft_protection_stop_failure_retry_normal_stop_restart_and_cold_draft_restore")
    finally:
        if not stopped:
            try:
                invoke(console, "stop", data, "portable")
            except Exception as error:
                evidence["ui_cleanup_error"] = repr(error)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("safe-exit"))
    args = parser.parse_args()
    require(os.name == "nt", "safe-exit verification requires Windows")
    root = claim(args.root)
    console = (OUTPUT / "portable/cutrans.exe").resolve()
    context_record(console.parent / "cutrans-context.json", "portable")
    require(not (console.parent / "data").exists(), "portable staging already contains user data")
    before = hashes(console.parent)
    evidence = {"format": "cutrans-safe-exit-verification/1", "root": str(root),
        "artifact_hashes": before, "checks": [], "passed": False}
    try:
        job_case(console, root, evidence, cancel=False)
        job_case(console, root, evidence, cancel=True)
        resume_case(console, root, evidence)
        stranded_case(console, root, evidence)
        invalid_control_case(console, root, evidence)
        failure_case(console, root, evidence)
        ui_case(console, root, evidence)
        require(hashes(console.parent) == before and not (console.parent / "data").exists(),
            "safe-exit verification modified the artifact or polluted portable staging")
        evidence["passed"] = True
        print("CUTRANS_SAFE_EXIT_VERIFY_OK wait=1 cancel=1 resume=1 stranded=1 control=1 save_retry=1 draft=1 restart=1 pack_pure=1")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        (root / "safe-exit.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)
        print(f"Safe-exit evidence retained: {root}")


if __name__ == "__main__":
    main()
