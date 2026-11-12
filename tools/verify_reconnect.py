"""Verify Shell reconnect after a real Host stop/restart without a visible window."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("reconnect"))
    args = parser.parse_args()
    require(os.name == "nt", "reconnect verification requires Windows")
    root = claim(args.root)
    console = (OUTPUT / "portable" / "cutrans.exe").resolve()
    require(console.is_file(), "portable cutrans.exe is missing; build portable first")
    data = root / "data"
    log_path = root / "reconnect-role.log"
    evidence = {"format": "cutrans-reconnect-verification/1", "root": str(root), "checks": [], "passed": False}
    process = None
    stopped = False
    try:
        invoke(console, "start", data, "portable")
        command = [str(console), "--role=shell", "--mode=portable", f"--data={data}",
            f"--shell-dir={console.parent / 'payload/desktop'}", "--assets-demo"]
        environment = os.environ.copy()
        environment["CUTRANS_RECONNECT_AUTO"] = "1"
        with log_path.open("xb") as log:
            process = automation_process.Popen(command, stdout=log,
                stderr=automation_process.subprocess.STDOUT, env=environment)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                text = log_path.read_bytes().decode("utf-8", errors="replace")
                if "CUTRANS_RECONNECT_READY" in text:
                    break
                require(process.poll() is None, f"the Shell exited before reconnect readiness: {text}")
                time.sleep(0.05)
            else:
                raise RuntimeError("the Shell did not reach reconnect readiness")
            invoke(console, "stop", data, "portable")
            stopped = True
            (data / "reconnect.host-lost").write_text("lost\n", encoding="utf-8")
            # The unmanaged command must fail while the Host is still down.
            # Wait for the Shell's verdict instead of racing the restart.
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                text = log_path.read_bytes().decode("utf-8", errors="replace")
                if "CUTRANS_COMMAND_UNKNOWN" in text:
                    break
                require(process.poll() is None,
                    f"the Shell failed before refusing the unmanaged command: {text}")
                time.sleep(0.05)
            else:
                raise RuntimeError("the Shell kept the Host loss from failing an unmanaged command")
            invoke(console, "start", data, "portable")
            stopped = False
            (data / "reconnect.host-restarted").write_text("restarted\n", encoding="utf-8")
            require(process.wait(timeout=120) == 0, "the hidden Shell failed after Host reconnect")
            invoke(console, "stop", data, "portable")
            stopped = True
        text = log_path.read_text(encoding="utf-8")
        require("CUTRANS_RECONNECT_LOST_DETECTED" in text, "the Shell did not detect the lost Host")
        require("CUTRANS_COMMAND_UNKNOWN" in text, "the Shell did not classify the unmanaged command as unknown")
        require("CUTRANS_RECONNECT_OK" in text, "the Shell did not complete reconnect")
        require("CUTRANS_NANOUI_DESKTOP_OK" in text, "the Shell did not complete its normal scenario after reconnect")
        evidence["checks"].append("host_stop_restart_auto_detect_shell_reconnect_without_visible_window")
        evidence["passed"] = True
        print("CUTRANS_RECONNECT_VERIFY_OK host_restart=1 auto_detect=1 shell_reconnect=1 normal_scenario=1 hidden=1")
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
        (root / "reconnect.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)


if __name__ == "__main__":
    main()
