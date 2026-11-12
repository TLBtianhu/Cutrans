"""Exercise controller, Host and NanoUI roles from the same packaged EXE.

All product processes use isolated claimed data roots. UI coverage is only the
hidden NanoUI Tester and D3D readback, never a visible window or input automation.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import time

sys.dont_write_bytecode = True

import automation_process
from build_paths import OUTPUT
from process_identity import find_pid
from verification_context import command_args, context_record
from verification_paths import check_root, claim, default_root, retain
from verify_host import invoke, run
from verify_input import hashes
import verify_host

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run_role(console: Path, data: Path, role: str, pack: Path | None, log_path: Path,
        document: Path | None = None, mode: str = "portable") -> str:
    command = [str(console), f"--role={role}", f"--mode={mode}", f"--data={data}"]
    if pack is not None:
        command.append(f"--shell-dir={pack}")
    command.append("--assets-demo")
    if document is not None:
        command.extend(["--open", str(document)])
    process = None
    with log_path.open("xb") as log:
        try:
            process = automation_process.Popen(command_args(command), stdout=log,
                stderr=automation_process.subprocess.STDOUT)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                text = log_path.read_bytes().decode("utf-8", errors="replace")
                if "CUTRANS_ENVIRONMENT_SESSION_OK" in text:
                    break
                require(process.poll() is None, f"the {role} role exited before environment activation: {text}")
                time.sleep(0.05)
            else:
                raise RuntimeError(f"the {role} role did not reach its environment barrier")
            actual = find_pid(console, data, "portable", role=role, known_pid=process.pid)
            require(actual == process.pid, f"the {role} process changed its executable or role identity")
            require(process.wait(timeout=90) == 0, f"the same-file {role} NanoUI scenario failed")
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except automation_process.subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
    text = log_path.read_text(encoding="utf-8")
    print(text, end="")
    return text


def desktop_case(console: Path, root: Path, evidence: dict) -> None:
    document = check_root(root / "desktop document.cut")
    shutil.copyfile(ROOT / "assets/examples/minimal.cut", document)
    data = check_root(root / "desktop data")
    stopped = False
    try:
        output = run([str(console), "--mode=portable", f"--data={data}",
            "--open", str(document), "--assets-demo"])
        require("CUTRANS_VM_START_OK already=0" in output and "CUTRANS_VM_ATTACH_ACCEPTED shell=desktop" in output,
            "the default controller did not start and accept the hidden desktop")
        shell = find_pid(console, data, "portable", role="shell", document=document,
            assets_demo=True)
        require(shell is not None, "the controller's desktop changed its executable or role identity")
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            lock = data / "session/runtime.lock"
            if lock.is_file() and "shell_id=desktop-shell" in lock.read_text(encoding="utf-8"):
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("the controller's desktop did not commit its Shell identity")
        _, started = invoke(console, "status", data, "portable")
        require(started["state"] == "running" and started["present"] >= 1,
            "the controller's desktop did not submit a real frame through the Host")
        require(find_pid(console, data, "portable", role="host") is not None,
            "the default controller started another Host executable")
        deadline = time.monotonic() + 10
        while find_pid(console, data, "portable", role="shell", known_pid=shell, timeout=0) is not None:
            require(time.monotonic() < deadline, "the hidden desktop did not exit after committing")
            time.sleep(0.05)
        text = run_role(console, data, "shell", console.parent / "payload/desktop",
            check_root(root / "desktop-role.log"), document)
        for marker in ("CUTRANS_SHELL_PRECHECK_OK id=desktop-shell", "CUTRANS_ENVIRONMENT_SESSION_OK",
                "CUTRANS_PREVIEW_OK", "CUTRANS_NANOUI_EDITOR_OK", "CUTRANS_SHELL_ASSETS_OK", "CUTRANS_NANOUI_D3D_OK",
                "CUTRANS_SHELL_FRAME_OK", "CUTRANS_SHELL_DETACHED"):
            require(marker in text, f"the same-file desktop missed {marker}")
        _, current = invoke(console, "status", data, "portable")
        require(current["state"] == "running" and current["boot"] == started["boot"]
            and current["present"] > started["present"], "the direct desktop replaced or stopped its Host")
        invoke(console, "stop", data, "portable")
        stopped = True
        evidence["checks"].append("controller_and_direct_same_file_shell_environment_assets_export_frame_lock_and_host_survival")
    finally:
        if not stopped:
            try:
                invoke(console, "stop", data, "portable")
            except Exception as error:
                evidence["desktop_cleanup_error"] = repr(error)


def library_case(console: Path, pack: Path, root: Path, evidence: dict) -> None:
    data = check_root(root / "library data")
    stopped = False
    try:
        _, started = invoke(console, "start", data, "portable")
        require(find_pid(console, data, "portable", role="host") is not None,
            "the controller did not start a same-file Host role")
        text = run_role(console, data, "library", pack, check_root(root / "library-role.log"))
        for marker in ("CUTRANS_SHELL_PRECHECK_OK id=nanoui-library", "CUTRANS_ENVIRONMENT_SESSION_OK",
                "CUTRANS_NANOUI_LIBRARY_OK", "CUTRANS_NANOUI_WORK_OK", "CUTRANS_NANOUI_D3D_OK",
                "CUTRANS_SHELL_DETACHED"):
            require(marker in text, f"the same-file library missed {marker}")
        require("shell_id=nanoui-library" in (data / "session/runtime.lock").read_text(encoding="utf-8"),
            "the same-file library did not commit its verified Shell identity")
        _, current = invoke(console, "status", data, "portable")
        require(current["state"] == "running" and current["boot"] == started["boot"],
            "closing the library stopped or replaced its Host")
        invoke(console, "stop", data, "portable")
        _, restarted = invoke(console, "start", data, "portable")
        require(restarted["boot"] == started["boot"] + 1 and restarted["abnormal"] == 0,
            "same-file Host did not recover cleanly after the library detached")
        require(find_pid(console, data, "portable", role="host") is not None,
            "the restarted Host changed executable identity")
        invoke(console, "stop", data, "portable")
        stopped = True
        evidence["checks"].append("same_file_library_environment_commit_host_survival_and_clean_restart")
    finally:
        if not stopped:
            try:
                invoke(console, "stop", data, "portable")
            except Exception as error:
                evidence["library_cleanup_error"] = repr(error)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("same-file"))
    args = parser.parse_args()
    require(os.name == "nt", "same-file process verification requires Windows")
    root = claim(args.root)
    console = (OUTPUT / "portable/cutrans.exe").resolve()
    require(console.is_file(), "the unified portable controller is missing")
    context_record(console.parent / "cutrans-context.json", "portable")
    require(not (console.parent / "data").exists(), "portable staging already contains user data")
    before = hashes(console.parent)
    evidence = {"format": "cutrans-same-file-verification/1", "root": str(root),
        "executable": str(console), "artifact_hashes": before, "checks": [], "passed": False}
    try:
        output = run([str(console), "--role=controller", f"--data={root / 'rejected'}"], expected=1)
        require("InvalidProcessRole" in output and not (root / "rejected").exists(),
            "an unknown process role reached environment activation")
        evidence["checks"].append("unknown_role_rejected_before_data_creation")
        verify_host.verify(console, console, "portable", root / "host")
        evidence["checks"].append("same_file_host_singleton_stop_failure_abnormal_recovery_and_restart")
        desktop_case(console, root, evidence)
        library_case(console, console.parent / "payload/nanoui-library", root, evidence)
        require(hashes(console.parent) == before and not (console.parent / "data").exists(),
            "same-file verification modified the artifact or polluted its staging data")
        evidence["passed"] = True
        print("CUTRANS_SAME_FILE_VERIFY_OK controller=1 host=1 shell=1 library=1 lifecycle=1 hidden_ui=1 pack_pure=1")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        (root / "same-file.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)
        print(f"Same-file evidence retained: {root}")


if __name__ == "__main__":
    main()
