"""Verify the distributed VM Host lifecycle through the real Windows console and pipe."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import signal
import sys
import time
from pathlib import Path

import automation_process

sys.dont_write_bytecode = True

from verify_input import ABI_VERSION, hashes

ROOT = Path(__file__).resolve().parents[1]
from build_paths import OUTPUT
from verification_paths import default_root, claim, retain, remove, check_root
from verification_context import command_args, canonical_path


def run(command: list[str], expected: int = 0, env: dict[str, str] | None = None) -> str:
    result = automation_process.run(command_args(command), capture_output=True, text=True, timeout=35, env=env)
    output = result.stdout + result.stderr
    print(output, end="")
    if result.returncode != expected:
        raise RuntimeError(f"unexpected exit code {result.returncode}, expected {expected}: {command}")
    return output


def state(output: str) -> dict[str, int | str]:
    matches = list(re.finditer(r"state=(\w+).*boot_id=(\d+).*last_shutdown_abnormal=(\d+).*abi=(\d+).*document=(\d+) present=(\d+)", output))
    if not matches:
        raise RuntimeError("missing real Host state: " + output)
    match = matches[-1]
    return {
        "state": match.group(1),
        "boot": int(match.group(2)),
        "abnormal": int(match.group(3)),
        "abi": int(match.group(4)),
        "document": int(match.group(5)),
        "present": int(match.group(6)),
    }


def invoke(console: Path, action: str, data: Path, mode: str, expected: int = 0) -> tuple[str, dict[str, int | str]]:
    output = run([str(console), action, f"--mode={mode}", f"--data={data}"], expected)
    return output, state(output)


def host_pid(host: Path, data: Path, mode: str) -> int | None:
    expected = f'"{canonical_path(host)}" --mode="{mode}" --purpose="verification" --data="{canonical_path(data)}"'
    env = os.environ.copy()
    env["CUTRANS_TEST_HOST_COMMAND"] = expected
    env["CUTRANS_TEST_HOST_PATH"] = canonical_path(host)
    script = "$p=Get-CimInstance Win32_Process -Filter \"Name='cutrans_vm_host.exe'\" | Where-Object { $_.ExecutablePath -ieq $env:CUTRANS_TEST_HOST_PATH -and $_.CommandLine -ieq $env:CUTRANS_TEST_HOST_COMMAND } | Select-Object -First 1; if ($p) { $p.ProcessId }"
    output = run(["powershell", "-NoProfile", "-Command", script], env=env).strip()
    return int(output) if output else None


def _verify(console: Path, host: Path, mode: str, root: Path) -> None:
    console = console.resolve()
    host = host.resolve()
    root = check_root(root)
    if root.exists():
        raise RuntimeError(f"Host verification root must be new: {root}")
    if mode not in {"portable", "installed"}:
        raise RuntimeError(f"unsupported verification mode: {mode}")
    if mode == "portable" and (console.parent / "data").exists():
        raise RuntimeError("portable staging already contains user data")
    claim(root)
    data = root / "primary data"
    before = hashes(console.parent)
    documents_backup = root / "documents backup"
    abnormal_pid: int | None = None
    try:
        _, current = invoke(console, "status", data, mode)
        assert current["state"] == "unreachable" and current["boot"] == 0, current
        _, current = invoke(console, "stop", data, mode)
        assert current["state"] == "stopped" and current["boot"] == 0, current

        output, current = invoke(console, "start", data, mode)
        assert "already=0" in output and current["state"] == "running" and current["boot"] == 1 and current["abnormal"] == 0 and current["abi"] == ABI_VERSION, current
        _, running = invoke(console, "status", data, mode)
        assert running == current, (running, current)
        output, duplicate = invoke(console, "start", data, mode)
        assert "already=1" in output and duplicate["boot"] == 1, duplicate
        duplicate_output = run([str(host), f"--mode={mode}", f"--data={data}"], expected=1)
        if "HostAlreadyRunning" not in duplicate_output:
            raise RuntimeError("second Host did not preserve the singleton instance lock")
        bootstrap = console.parent / "cutrans_bootstrap.exe"
        legacy_output = run([str(bootstrap), "--diag", f"--mode={mode}", f"--data={data}"], expected=1)
        if "HostAlreadyRunning" not in legacy_output:
            raise RuntimeError("a second headless Runtime became a writer beside the Host")
        _, current = invoke(console, "status", data, mode)
        assert current["boot"] == 1 and current["state"] == "running", current

        _, current = invoke(console, "stop", data, mode)
        assert current["state"] == "stopped" and current["boot"] == 1 and current["abnormal"] == 0, current
        output, current = invoke(console, "stop", data, mode)
        assert "already=1" in output and current["state"] == "stopped", current

        _, current = invoke(console, "start", data, mode)
        assert current["boot"] == 2 and current["abnormal"] == 0, current
        documents = data / "documents"
        if documents.exists():
            shutil.move(documents, documents_backup)
        documents.write_text("deliberately not a directory", encoding="utf-8")
        output, failed = invoke(console, "stop", data, mode, expected=1)
        assert failed["state"] == "degraded" and failed["boot"] == 2, failed
        if "CUTRANS_VM_STOP_FAIL" not in output:
            raise RuntimeError("failed save was reported as a normal stop")
        _, current = invoke(console, "status", data, mode)
        assert current["state"] == "degraded" and current["boot"] == 2, current
        documents.unlink()
        if documents_backup.exists():
            shutil.move(documents_backup, documents)
        else:
            documents.mkdir()
        _, current = invoke(console, "stop", data, mode)
        assert current["state"] == "stopped" and current["boot"] == 2 and current["abnormal"] == 0, current

        _, current = invoke(console, "start", data, mode)
        assert current["boot"] == 3 and current["abnormal"] == 0, current
        _, current = invoke(console, "restart", data, mode)
        assert current["state"] == "running" and current["boot"] == 4 and current["abnormal"] == 0, current
        abnormal_pid = host_pid(host, data, mode)
        if abnormal_pid is None:
            raise RuntimeError("could not identify the Host owned by this isolated test")
        os.kill(abnormal_pid, signal.SIGTERM)
        for _ in range(100):
            _, current = invoke(console, "status", data, mode)
            if current["state"] == "unreachable":
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("abnormal Host termination did not become observable")
        assert current["boot"] == 4 and current["abnormal"] == 0, current
        abnormal_pid = None
        _, current = invoke(console, "start", data, mode)
        assert current["state"] == "running" and current["boot"] == 5 and current["abnormal"] == 1, current
        _, current = invoke(console, "stop", data, mode)
        assert current["state"] == "stopped" and current["boot"] == 5 and current["abnormal"] == 0, current

        if hashes(console.parent) != before:
            raise RuntimeError("Host verification modified the application or Runtime Pack")
        if mode == "portable" and (console.parent / "data").exists():
            raise RuntimeError("Host verification polluted portable staging")
        print("CUTRANS_VM_HOST_VERIFY_OK start=1 idempotent=1 singleton=1 stop=1 stop_failure=1 abnormal_recovery=1 isolated_data=1")
    finally:
        documents = data / "documents"
        if documents.is_file():
            documents.unlink()
            if documents_backup.exists() and not documents.exists():
                shutil.move(documents_backup, documents)
        try:
            invoke(console, "stop", data, mode)
        except Exception as error:
            print(f"Host cleanup stop: {error}")
        if abnormal_pid is not None:
            try:
                os.kill(abnormal_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        if root.exists():
            retain(root)


def verify(console: Path, host: Path, mode: str, root: Path) -> None:
    output = run([
        sys.executable,
        str(Path(__file__).resolve()),
        "--console",
        str(console.resolve()),
        "--host",
        str(host.resolve()),
        "--mode",
        mode,
        "--root",
        str(check_root(root)),
    ])
    if "CUTRANS_VM_HOST_VERIFY_OK" not in output:
        raise RuntimeError("isolated Host probe did not report success")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--console", type=Path, default=OUTPUT / "portable/cutrans_vm.exe")
    parser.add_argument("--host", type=Path, default=OUTPUT / "portable/cutrans_vm_host.exe")
    parser.add_argument("--mode", choices=("portable", "installed"), default="portable")
    parser.add_argument("--root", type=Path, default=default_root("host-user"))
    args = parser.parse_args()
    _verify(args.console, args.host, args.mode, args.root)


if __name__ == "__main__":
    main()
