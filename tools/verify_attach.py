"""Verify a real Host survives repeated Shell attachment, asset work, and clean stops."""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True

from verify_host import invoke, run
from verify_input import hashes
from verify_shell import start_and_verify

ROOT = Path(__file__).resolve().parents[1]
from build_paths import OUTPUT
from verification_paths import default_root, claim, retain, remove, check_root
from verification_context import canonical_path


def attached_pid(shell: Path, data: Path, document: Path, mode: str) -> int:
    expected = f'"{canonical_path(shell)}" --mode="{mode}" --purpose="verification" --data="{canonical_path(data)}" --open="{canonical_path(document)}"'
    env = os.environ.copy()
    env["CUTRANS_TEST_SHELL_COMMAND"] = expected
    env["CUTRANS_TEST_SHELL_PATH"] = canonical_path(shell)
    script = "$p=Get-CimInstance Win32_Process -Filter \"Name='cutrans_shell.exe'\" | Where-Object { $_.ExecutablePath -ieq $env:CUTRANS_TEST_SHELL_PATH -and $_.CommandLine -ieq $env:CUTRANS_TEST_SHELL_COMMAND } | Select-Object -First 1; if ($p) { $p.ProcessId }"
    for _ in range(50):
        output = run(["powershell", "-NoProfile", "-Command", script], env=env).strip()
        if output:
            return int(output)
        time.sleep(0.1)
    raise RuntimeError("attach did not produce the expected Shell process")


def _verify(console: Path, shell: Path, mode: str, root: Path) -> None:
    console = console.resolve()
    shell = shell.resolve()
    root = check_root(root)
    if root.exists():
        raise RuntimeError(f"attach verification root must be new: {root}")
    if mode not in {"portable", "installed"}:
        raise RuntimeError(f"unsupported verification mode: {mode}")
    if mode == "portable" and (console.parent / "data").exists():
        raise RuntimeError("portable staging already contains user data")
    claim(root)
    document = root / "attach document.cut"
    shutil.copyfile(ROOT / "assets/examples/minimal.cut", document)
    data = root / "attach data"
    before = hashes(console.parent)
    attach_pid: int | None = None
    try:
        _, current = invoke(console, "start", data, mode)
        assert current["state"] == "running" and current["boot"] == 1, current
        initial_document = current["document"]
        output = run([str(console), "attach", f"--mode={mode}", f"--data={data}", "--open", str(document)])
        if "CUTRANS_VM_ATTACH_ACCEPTED" not in output:
            raise RuntimeError("attach was not accepted by the console")
        attach_pid = attached_pid(shell, data, document, mode)
        os.kill(attach_pid, signal.SIGTERM)
        attach_pid = None
        _, current = invoke(console, "status", data, mode)
        assert current["state"] == "running" and current["boot"] == 1 and current["document"] == initial_document, current

        start_and_verify(shell, document, data, mode, cleanup=False, settle_seconds=0.5)
        _, current = invoke(console, "status", data, mode)
        assert current["state"] == "running" and current["boot"] == 1 and current["document"] == initial_document and current["present"] >= 1, current

        start_and_verify(shell, document, data, mode, cleanup=False, assets_demo=True, settle_seconds=0.5)
        _, current = invoke(console, "status", data, mode)
        assert current["state"] == "running" and current["boot"] == 1 and current["document"] != initial_document and current["present"] >= 2, current

        start_and_verify(shell, document, data, mode, cleanup=False, playback_frames=4, settle_seconds=0.5)
        _, current = invoke(console, "status", data, mode)
        assert current["state"] == "running" and current["boot"] == 1 and current["present"] >= 3, current
        lock_text = (data / "session/runtime.lock").read_text(encoding="utf-8")
        if "runtime_id=cutrans-vm" not in lock_text or "shell_id=" in lock_text or str(root) in lock_text or "C:\\" in lock_text:
            raise RuntimeError("an abruptly terminated attached Shell changed the committed selection")

        _, current = invoke(console, "stop", data, mode)
        assert current["state"] == "stopped" and current["boot"] == 1 and current["abnormal"] == 0, current
        _, current = invoke(console, "start", data, mode)
        assert current["state"] == "running" and current["boot"] == 2 and current["abnormal"] == 0, current
        _, current = invoke(console, "stop", data, mode)
        assert current["state"] == "stopped" and current["boot"] == 2 and current["abnormal"] == 0, current
        if hashes(console.parent) != before:
            raise RuntimeError("Shell attachment modified the application or Pack")
        if mode == "portable" and (console.parent / "data").exists():
            raise RuntimeError("Shell attachment polluted portable staging")
        print("CUTRANS_VM_ATTACH_VERIFY_OK attach=4 host_survives=1 assets=1 frame=1 lock=1 restart=1")
    finally:
        if attach_pid is not None:
            try:
                os.kill(attach_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        invoke(console, "stop", data, mode)
        if root.exists():
            retain(root)


def verify(console: Path, shell: Path, mode: str, root: Path) -> None:
    output = run([
        sys.executable,
        str(Path(__file__).resolve()),
        "--console",
        str(console.resolve()),
        "--shell",
        str(shell.resolve()),
        "--mode",
        mode,
        "--root",
        str(check_root(root)),
    ])
    if "CUTRANS_VM_ATTACH_VERIFY_OK" not in output:
        raise RuntimeError("isolated Shell attachment probe did not report success")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--console", type=Path, default=OUTPUT / "portable/cutrans_vm.exe")
    parser.add_argument("--shell", type=Path, default=OUTPUT / "portable/cutrans_shell.exe")
    parser.add_argument("--mode", choices=("portable", "installed"), default="portable")
    parser.add_argument("--root", type=Path, default=default_root("attach-user"))
    args = parser.parse_args()
    _verify(args.console, args.shell, args.mode, args.root)


if __name__ == "__main__":
    main()
