"""Read-only identity checks for processes owned by an isolated test case."""
from __future__ import annotations

import os
from pathlib import Path
import time

import automation_process
from verification_context import canonical_path


def find_pid(executable: Path, data: Path, mode: str, *, role: str | None = None,
        document: Path | None = None, shell_dir: Path | None = None,
        assets_demo: bool = False, timeout: float = 5.0, known_pid: int | None = None) -> int | None:
    if role not in {None, "host", "shell", "library"}:
        raise ValueError("unknown internal process role")
    if known_pid is not None and (known_pid < 1 or role is None):
        raise ValueError("a direct process identity check needs a valid PID and role")
    expected = f'"{canonical_path(executable)}"'
    if role is not None:
        expected += f" --role={role}"
    expected += f' --mode="{mode}" --purpose="verification" --data="{canonical_path(data)}"'
    if document is not None:
        expected += f' --open="{canonical_path(document)}"'
    if shell_dir is not None:
        expected += f' --shell-dir="{canonical_path(shell_dir)}"'
    if assets_demo:
        expected += " --assets-demo"
    env = os.environ.copy()
    env["CUTRANS_TEST_PROCESS_NAME"] = executable.name
    env["CUTRANS_TEST_PROCESS_PATH"] = canonical_path(executable)
    env["CUTRANS_TEST_PROCESS_COMMAND"] = expected
    script = "$p=Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq $env:CUTRANS_TEST_PROCESS_NAME -and $_.ExecutablePath -ieq $env:CUTRANS_TEST_PROCESS_PATH -and $_.CommandLine -ieq $env:CUTRANS_TEST_PROCESS_COMMAND } | Select-Object -First 1; if ($p) { $p.ProcessId }"
    if known_pid is not None:
        env["CUTRANS_TEST_PROCESS_ID"] = str(known_pid)
        env["CUTRANS_TEST_PROCESS_ROLE"] = f"--role={role}"
        script = "$p=Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -eq [uint32]$env:CUTRANS_TEST_PROCESS_ID -and $_.ExecutablePath -ieq $env:CUTRANS_TEST_PROCESS_PATH -and $_.CommandLine.Contains($env:CUTRANS_TEST_PROCESS_ROLE) } | Select-Object -First 1; if ($p) { $p.ProcessId }"
    deadline = time.monotonic() + timeout
    while True:
        result = automation_process.run(["powershell", "-NoProfile", "-Command", script],
            capture_output=True, text=True, timeout=15, env=env)
        if result.returncode:
            raise RuntimeError("read-only process identity query failed: " + result.stdout + result.stderr)
        output = result.stdout.strip()
        if output:
            return int(output)
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.05)
