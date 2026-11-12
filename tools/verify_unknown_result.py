"""Verify a managed edit whose reply is lost across a real Host restart."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True

import automation_process
from build_paths import OUTPUT
from verification_paths import claim, default_root, retain
from verify_host import invoke

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def wait_for(log_path: Path, marker: str, process, timeout: float = 30) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        text = log_path.read_bytes().decode("utf-8", errors="replace")
        if marker in text:
            return text
        require(process.poll() is None, f"the hidden Shell exited before {marker}: {text}")
        time.sleep(0.05)
    raise RuntimeError(f"the hidden Shell did not report {marker}")


def start_shell(console: Path, data: Path, log_path: Path, extra_env: dict[str, str]):
    command = [str(console), "--role=shell", "--mode=portable", f"--data={data}",
        f"--shell-dir={console.parent / 'payload/desktop'}", "--assets-demo"]
    environment = os.environ.copy()
    environment.update(extra_env)
    log = log_path.open("xb")
    try:
        process = automation_process.Popen(command, stdout=log,
            stderr=automation_process.subprocess.STDOUT, env=environment)
    finally:
        log.close()
    return process


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("unknown-result"))
    args = parser.parse_args()
    require(os.name == "nt", "unknown-result verification requires Windows")
    root = claim(args.root)
    console = (OUTPUT / "portable" / "cutrans.exe").resolve()
    require(console.is_file(), "portable cutrans.exe is missing; build portable first")
    data = root / "data"
    desktop_log = root / "desktop-role.log"
    demo_log = root / "unknown-role.log"
    evidence = {"format": "cutrans-unknown-result-verification/1", "root": str(root), "checks": [], "passed": False}
    process = None
    stopped = False
    try:
        # First prove the ordinary hidden desktop scenario works, so the later
        # document edits of the fault demo cannot mask a normal regression.
        invoke(console, "start", data, "portable")
        process = start_shell(console, data, desktop_log, {})
        require(process.wait(timeout=120) == 0, "the ordinary hidden desktop scenario failed")
        desktop = desktop_log.read_text(encoding="utf-8")
        require("CUTRANS_NANOUI_DESKTOP_OK" in desktop, "the ordinary desktop markers are missing")
        evidence["checks"].append("ordinary_hidden_desktop_before_fault")
        invoke(console, "stop", data, "portable")
        stopped = True

        # The Host commits the first workspace request and closes the connection
        # before replying. Only this verification sets the injection variable.
        os.environ["CUTRANS_TEST_DROP_WORKSPACE_REPLY"] = "1"
        try:
            invoke(console, "start", data, "portable")
        finally:
            os.environ.pop("CUTRANS_TEST_DROP_WORKSPACE_REPLY", None)
        stopped = False
        process = start_shell(console, data, demo_log, {"CUTRANS_UNKNOWN_RESULT_DEMO": "1"})
        wait_for(demo_log, "CUTRANS_UNKNOWN_PENDING", process)
        invoke(console, "stop", data, "portable")
        stopped = True
        invoke(console, "start", data, "portable")
        stopped = False
        (data / "unknown.host-restarted").write_text("restarted\n", encoding="utf-8")
        require(process.wait(timeout=120) == 0, "the hidden Shell failed after the unknown result")
        text = demo_log.read_text(encoding="utf-8")
        require("CUTRANS_UNKNOWN_CLEARED" in text, "the Shell did not clear the pending request")
        require("CUTRANS_UNKNOWN_RECOVERED" in text, "the Shell did not recover with a new explicit edit")
        require("CUTRANS_UNKNOWN_DEMO_DONE" in text, "the unknown-result demo did not finish")
        pending = re.search(r"CUTRANS_UNKNOWN_PENDING nodes_before=(\d+) nodes_after=(\d+)", text)
        nodes = re.search(r"CUTRANS_UNKNOWN_NODES after_lost=(\d+) after_recovery=(\d+)", text)
        require(pending and nodes, "the demo did not report node counts")
        before, after_lost = int(pending.group(1)), int(pending.group(2))
        after_clear, after_recovery = int(nodes.group(1)), int(nodes.group(2))
        require(after_lost == before + 1, "the lost reply did not leave exactly one committed edit")
        require(after_clear == after_lost, "the new-epoch retry committed the request twice")
        require(after_recovery == after_lost + 1, "the explicit recovery edit did not commit once")
        cleared = next(line for line in text.splitlines() if "CUTRANS_UNKNOWN_CLEARED" in line)
        require("无法确认" in cleared, "the clear path did not explain the unknown result")
        evidence["checks"].append("lost_reply_commits_once_then_stops_as_unknown_without_replay")
        invoke(console, "stop", data, "portable")
        stopped = True

        evidence["passed"] = True
        print("CUTRANS_UNKNOWN_VERIFY_OK pending=1 cleared=1 recovered=1 nodes=1 desktop=1 hidden=1")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
        if not stopped:
            try:
                invoke(console, "stop", data, "portable")
            except Exception as error:
                evidence["cleanup_error"] = repr(error)
        (root / "unknown-result.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)


if __name__ == "__main__":
    main()
