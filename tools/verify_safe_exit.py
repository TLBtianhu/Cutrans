"""Verify the environment's safe exit in the single-process runtime.

Job draining and cancellation, refused new business, resume, invalid control
and abnormal ends run through the headless ``exec`` front end; draft
protection, a real save failure and its retry run through the desktop App's
hidden exit scenario. Both use the same in-process exit control.
"""
from __future__ import annotations

import argparse
import ctypes as c
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from environment_harness import exec_script, require, run_app, status
from verification_context import context_record
from verification_paths import check_root, claim, default_root, retain
from verify_input import hashes
from verify_jobs_async import BIG
from verify_resource_operations import configure
from verify_work_documents import WorkClient

ACCEPTED, INVALID_STATE, FAILED_EXIT = 1, 5, 1


def claimed(console, root, name):
    """A data root claimed by one empty instance, ready for fixtures."""
    data = check_root(root / f"{name} data")
    exec_script(console, data, "portable", [{"call": "stop"}], root / f"{name}-claim.jsonl")
    return data


def job_case(console, root, evidence, cancel):
    name = "cancel" if cancel else "wait"
    data = claimed(console, root, name)
    fixture = data / "fixtures/document.cut"
    fixture.parent.mkdir(parents=True)
    fixture.write_text(BIG, encoding="utf-8")
    calls = [{"call": "command", "name": "doc.open", "arg": "session://fixtures/document.cut", "expect": 0}]
    calls += [{"call": "command", "name": "editor.export.png", "arg": f"session://exports/{name}-{index}.png", "expect": ACCEPTED}
        for index in range(3)]
    calls += [{"call": "jobs"}, {"call": "prepare_stop"},
        {"call": "command", "name": "editor.export.png", "arg": f"session://exports/{name}-rejected.png", "expect": INVALID_STATE}]
    if cancel:
        calls.append({"call": "cancel_jobs"})
    calls += [{"call": "wait_jobs", "timeout_ms": 90000}, {"call": "jobs"}, {"call": "stop"}]
    _, results = exec_script(console, data, "portable", calls, root / f"{name}.jsonl", timeout=150)
    require(results[4]["page"]["active_count"] > 0, f"{name} fixture has no active jobs to exercise")
    page = results[-2]["page"]
    if cancel:
        require(any(item["state"] == "cancelled" and item["cancel_requested"] for item in page["items"]),
            "cooperative cancellation did not persist a cancelled job")
    else:
        require(all(item["state"] == "succeeded" for item in page["items"]),
            "waiting for existing jobs changed or cancelled their outcomes")
    require(not (data / f"exports/{name}-rejected.png").exists(), "new business was admitted while exiting")
    current = status(console, data, "portable")
    require(current["state"] == "stopped" and current["abnormal"] == 0, f"{name} exit did not stop normally: {current}")
    evidence["checks"].append(f"{name}_existing_jobs_while_stopping_and_new_business_rejected")


def resume_case(console, root, evidence):
    data = check_root(root / "resume data")
    _, results = exec_script(console, data, "portable", [
        {"call": "prepare_stop"},
        {"call": "command", "name": "editor.export.png", "arg": "session://exports/resume-rejected.png", "expect": INVALID_STATE},
        {"call": "resume_work"},
        {"call": "command", "name": "editor.invert.add", "arg": "c1", "expect": 0},
        {"call": "stop"},
    ], root / "resume.jsonl")
    require(results[-1]["stopped"], "resumed environment did not stop normally")
    evidence["checks"].append("resume_reopens_business_in_the_same_instance")


def invalid_control_case(console, root, evidence):
    """An invalid control transition fails the caller; the instance still stops normally."""
    data = check_root(root / "invalid control data")
    output, results = exec_script(console, data, "portable", [{"call": "resume_work"}],
        root / "invalid.jsonl", expected=FAILED_EXIT)
    require(results and results[0]["ok"] is False and "InvalidEnvironmentState" in output,
        "resume_work outside an exit was not refused")
    current = status(console, data, "portable")
    require(current["state"] == "stopped" and current["abnormal"] == 0,
        "a refused control transition did not still end with a normal stop")
    evidence["checks"].append("invalid_control_transition_is_refused_and_the_instance_still_stops_normally")


def abnormal_case(console, root, evidence):
    """An instance that ends without any stop is reported by the next one."""
    data = check_root(root / "abnormal data")
    exec_script(console, data, "portable", [{"call": "prepare_stop"}, {"call": "crash"}], root / "crash.jsonl", expected=70)
    current = status(console, data, "portable")
    require(current["state"] == "stopping", f"the crashed instance left an unexpected record: {current}")
    output, _ = exec_script(console, data, "portable", [{"call": "stop"}], root / "after-crash.jsonl")
    require("CUTRANS_ENVIRONMENT_READY boot_id=2 abnormal_previous=1" in output,
        "the next instance did not report the abnormal end")
    current = status(console, data, "portable")
    require(current["state"] == "stopped" and current["abnormal"] == 0, "recovery did not end with a normal stop")
    evidence["checks"].append("crash_during_exit_is_reported_by_the_next_instance_which_stops_normally")


def single_writer_case(console, root, evidence):
    """A second instance on a live data root is refused before touching it."""
    data = check_root(root / "single writer data")
    exec_script(console, data, "portable", [{"call": "stop"}], root / "single-claim.jsonl")
    lock = data / "session/instance.lock"
    kernel = c.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.restype = c.c_void_p
    kernel.CreateFileW.argtypes = [c.c_wchar_p, c.c_uint32, c.c_uint32, c.c_void_p, c.c_uint32, c.c_uint32, c.c_void_p]
    kernel.CloseHandle.argtypes = [c.c_void_p]
    handle = kernel.CreateFileW(str(lock), 0xC0000000, 0, None, 4, 0x80, None)
    require(handle not in (None, c.c_void_p(-1).value), "could not hold the instance lock for the test")
    try:
        output, _ = exec_script(console, data, "portable", [{"call": "stop"}], root / "single-second.jsonl", expected=1)
        require("EnvironmentAlreadyRunning" in output, "a second instance shared a live data root")
    finally:
        kernel.CloseHandle(handle)
    evidence["checks"].append("a_live_data_root_admits_exactly_one_instance")


def ui_case(console, root, evidence):
    data = check_root(root / "ui data")
    output = run_app(console, data, check_root(root / "ui.log"), demo="--exit-demo")
    require("CUTRANS_SAFE_EXIT_DRAFT_OK" in output and "work_revision=1" in output and "stop_retry=1" in output
        and "CUTRANS_SAFE_EXIT_OK" in output,
        "the NanoUI exit button did not preserve a draft, report a real failure and retry to a normal stop")
    require("shell_id=desktop-shell" in (data / "session/runtime.lock").read_text(encoding="utf-8"),
        "the App identity was not committed by the safe exit")
    current = status(console, data, "portable")
    require(current["state"] == "stopped" and current["abnormal"] == 0, "safe exit did not persist a normal stop")
    output, _ = exec_script(console, data, "portable", [{"call": "stop"}], root / "ui-restart.jsonl")
    require("abnormal_previous=0" in output, "the environment did not restart normally after safe exit")
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
    evidence = {"format": "cutrans-safe-exit-verification/2", "root": str(root),
        "artifact_hashes": before, "checks": [], "passed": False}
    try:
        job_case(console, root, evidence, cancel=False)
        job_case(console, root, evidence, cancel=True)
        resume_case(console, root, evidence)
        invalid_control_case(console, root, evidence)
        abnormal_case(console, root, evidence)
        single_writer_case(console, root, evidence)
        ui_case(console, root, evidence)
        require(hashes(console.parent) == before and not (console.parent / "data").exists(),
            "safe-exit verification modified the artifact or polluted portable staging")
        evidence["passed"] = True
        print("CUTRANS_SAFE_EXIT_VERIFY_OK wait=1 cancel=1 admission=1 resume=1 control=1 abnormal=1 single_writer=1 save_retry=1 draft=1 restart=1 pack_pure=1")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        (root / "safe-exit.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)
        print(f"Safe-exit evidence retained: {root}")


if __name__ == "__main__":
    main()
