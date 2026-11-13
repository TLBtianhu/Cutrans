"""Single-process environment helpers for verification scripts.

Since 2026-11-12 Cutrans has no Host process: every run of ``cutrans.exe`` is
one environment instance holding the Runtime, the job driver and its front end.
These helpers replace the retired Host ``start``/``attach``/``stop`` driving:

* ``exec_script`` runs a JSON-lines call script headless in a real instance;
* ``run_app`` runs the desktop or library App with one of its built-in hidden
  self-test scenarios and returns its log;
* ``status`` reads the persisted lifecycle record (there is no live process to ask).
"""
from __future__ import annotations

import json
import re
import shutil
import time
from pathlib import Path

import automation_process
from build_paths import ROOT
from verification_context import command_args
from verification_paths import check_root


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(command: list[str], expected: int = 0, env: dict[str, str] | None = None, timeout: float = 60) -> str:
    result = automation_process.run(command_args(command), capture_output=True, text=True, timeout=timeout, env=env)
    output = result.stdout + result.stderr
    print(output, end="")
    if result.returncode != expected:
        raise RuntimeError(f"unexpected exit code {result.returncode}, expected {expected}: {command}")
    return output


STATUS = re.compile(r"CUTRANS_ENVIRONMENT_STATUS state=(\w+) mode=(\w+) boot_id=(\d+) last_shutdown_abnormal=(\d+) abi=(\d+) document=(\d+) present=(\d+)")


def status(console: Path, data: Path, mode: str) -> dict[str, int | str]:
    output = run([str(console), "status", f"--mode={mode}", f"--data={data}"])
    match = STATUS.search(output)
    require(match is not None, "missing persisted environment status: " + output)
    return {
        "state": match.group(1),
        "boot": int(match.group(3)),
        "abnormal": int(match.group(4)),
        "abi": int(match.group(5)),
        "document": int(match.group(6)),
        "present": int(match.group(7)),
    }


def exec_results(output: str) -> list[dict]:
    return [json.loads(line.split("CUTRANS_EXEC ", 1)[1]) for line in output.splitlines() if line.startswith("CUTRANS_EXEC ")]


def exec_script(console: Path, data: Path, mode: str, calls: list[dict], script: Path, expected: int = 0,
        env: dict[str, str] | None = None, timeout: float = 90, extra: list[str] | None = None) -> tuple[str, list[dict]]:
    """Run ``calls`` in one environment instance; ``script`` must not exist yet."""
    script = check_root(script)
    with script.open("x", encoding="utf-8", newline="\n") as handle:
        for call in calls:
            handle.write(json.dumps(call, ensure_ascii=False) + "\n")
    command = [str(console), "exec", f"--mode={mode}", f"--data={data}", f"--script={script}"]
    command.extend(extra or [])
    output = run(command, expected, env, timeout)
    return output, exec_results(output)


def run_app(console: Path, data: Path, log_path: Path, *, flavor: str = "desktop", shell_dir: Path | None = None,
        document: Path | None = None, demo: str = "--assets-demo", mode: str = "portable",
        expected: int = 0, env: dict[str, str] | None = None, timeout: float = 120) -> str:
    """Run one App self-test scenario to completion and return its log."""
    command = [str(console)]
    if flavor == "library":
        command.append("library")
    else:
        require(flavor == "desktop", f"unknown App flavor {flavor}")
    command.extend([f"--mode={mode}", f"--data={data}"])
    if shell_dir is not None:
        command.append(f"--shell-dir={shell_dir}")
    if demo:
        command.append(demo)
    if document is not None:
        command.extend(["--open", str(document)])
    process = None
    with log_path.open("xb") as log:
        try:
            process = automation_process.Popen(command_args(command), stdout=log,
                stderr=automation_process.subprocess.STDOUT, env=env)
            code = process.wait(timeout=timeout)
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except automation_process.subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
    text = log_path.read_text(encoding="utf-8", errors="replace")
    print(text, end="")
    require(code == expected, f"the {flavor} App exited with {code}, expected {expected}")
    return text


DESKTOP_MARKERS = (
    "CUTRANS_SHELL_PRECHECK_OK id=desktop-shell", "CUTRANS_ENVIRONMENT_READY", "CUTRANS_ENVIRONMENT_SESSION_OK",
    "CUTRANS_PREVIEW_OK", "CUTRANS_NANOUI_EDITOR_OK", "CUTRANS_SHELL_ASSETS_OK", "CUTRANS_NANOUI_D3D_OK",
    "CUTRANS_SHELL_FRAME_OK", "CUTRANS_ENVIRONMENT_STOPPED", "CUTRANS_ENVIRONMENT_CLOSED mode=",
)

LIBRARY_MARKERS = (
    "CUTRANS_SHELL_PRECHECK_OK id=nanoui-library", "CUTRANS_ENVIRONMENT_READY", "CUTRANS_ENVIRONMENT_SESSION_OK",
    "CUTRANS_NANOUI_LIBRARY_OK", "CUTRANS_NANOUI_WORK_OK", "CUTRANS_NANOUI_D3D_OK", "CUTRANS_ENVIRONMENT_STOPPED",
)


def desktop_case(console: Path, root: Path, evidence: dict, mode: str = "portable") -> None:
    """The desktop App runs its hidden scenario in one process and stops normally."""
    document = check_root(root / "desktop document.cut")
    shutil.copyfile(ROOT / "assets/examples/minimal.cut", document)
    data = check_root(root / "desktop data")
    text = run_app(console, data, check_root(root / "desktop.log"), document=document, mode=mode)
    for marker in DESKTOP_MARKERS:
        require(marker in text, f"the desktop environment missed {marker}")
    require("stopped=1" in text, "the desktop environment did not record a normal stop")
    require("shell_id=desktop-shell" in (data / "session/runtime.lock").read_text(encoding="utf-8"),
        "the desktop did not commit its verified App identity")
    first = status(console, data, mode)
    require(first["state"] == "stopped" and first["boot"] == 1 and first["abnormal"] == 0,
        f"the desktop environment did not persist a clean first stop: {first}")
    again = run_app(console, data, check_root(root / "desktop-again.log"), document=document, mode=mode)
    require("CUTRANS_ENVIRONMENT_READY boot_id=2 abnormal_previous=0" in again,
        "a second desktop instance did not continue the boot sequence cleanly")
    evidence["checks"].append("single_process_desktop_scenario_preview_assets_frame_identity_and_clean_restart")


def library_case(console: Path, pack: Path, root: Path, evidence: dict, mode: str = "portable") -> None:
    """The library App is another front end of the same kind of instance."""
    data = check_root(root / "library data")
    text = run_app(console, data, check_root(root / "library.log"), flavor="library", shell_dir=pack, mode=mode)
    for marker in LIBRARY_MARKERS:
        require(marker in text, f"the library environment missed {marker}")
    require("shell_id=nanoui-library" in (data / "session/runtime.lock").read_text(encoding="utf-8"),
        "the library did not commit its verified App identity")
    current = status(console, data, mode)
    require(current["state"] == "stopped" and current["abnormal"] == 0,
        f"closing the library did not stop its environment normally: {current}")
    evidence["checks"].append("single_process_library_scenario_identity_and_normal_stop")


def wait_for(predicate, timeout: float, message: str) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise RuntimeError(message)
