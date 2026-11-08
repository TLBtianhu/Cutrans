"""Verify NanoUI activation and distribution through a real isolated VM Host."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

sys.dont_write_bytecode = True

from verify_host import invoke, run
from verify_input import hashes

ROOT = Path(__file__).resolve().parents[1]
from build_paths import OUTPUT
from verification_paths import default_root, claim, retain, remove, check_root
from verification_context import canonical_path, context_record


def frontend(executable: Path, mode: str, data: Path, default_paths: bool, pack: Path | None, expected: int = 0) -> str:
    # Default resolution is checked read-only; every running fixture has an
    # explicit isolated data root and verification purpose.
    command = [str(executable), f"--mode={mode}", f"--data={data}"]
    if pack is not None:
        command.append(f"--shell-dir={pack}")
    command.append("--assets-demo")
    return run(command, expected=expected)


def successful_frontend(executable: Path, mode: str, data: Path, default_paths: bool, pack: Path | None) -> None:
    output = frontend(executable, mode, data, default_paths, pack)
    required = (
        "CUTRANS_SHELL_PRECHECK_OK id=nanoui-library",
        "CUTRANS_NANOUI_LIBRARY_OK",
        "CUTRANS_NANOUI_WORK_OK",
        "CUTRANS_NANOUI_D3D_OK",
        "CUTRANS_NANOUI_DYNAMIC_OK",
        "CUTRANS_SHELL_DETACHED",
    )
    if any(marker not in output for marker in required):
        raise RuntimeError("NanoUI did not complete precheck, real UI, dynamic texture, D3D, commit and Host checks")


def broken_pack(source: Path, target: Path) -> Path:
    shutil.copytree(source, target)
    payload = b"deliberately not a PNG"
    sample = target / "assets/examples/pngtest.png"
    sample.write_bytes(payload)
    manifest_path = target / "shell-pack.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["version"] += "-broken"
    record = next(file for file in manifest["files"] if file["path"] == "assets/examples/pngtest.png")
    record["byteLength"] = len(payload)
    record["sha256"] = hashlib.sha256(payload).hexdigest()
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return target


def failed_frontend_preserves_lock(executable: Path, pack: Path, mode: str, data: Path, default_paths: bool) -> None:
    lock = data / "session/runtime.lock"
    before = lock.read_bytes()
    output = frontend(executable, mode, data, default_paths, pack, expected=1)
    if "CUTRANS_SHELL_PRECHECK_OK id=nanoui-library" not in output or "CUTRANS_NANOUI_LIBRARY_FAIL" not in output:
        raise RuntimeError("the invalid resource did not reach the real frontend after Host precheck")
    if "CUTRANS_SHELL_DETACHED" in output or lock.read_bytes() != before:
        raise RuntimeError("a failed NanoUI frontend changed the committed Shell selection")


def verify_library_command(console: Path, mode: str, root: Path, candidate: Path) -> None:
    success_data = root / "command success data"
    try:
        output = run([
            str(console),
            "library",
            f"--mode={mode}",
            f"--data={success_data}",
            "--assets-demo",
        ])
        if "CUTRANS_VM_START_OK already=0" not in output or "CUTRANS_VM_ATTACH_OK shell=nanoui_library" not in output:
            raise RuntimeError("library did not start the Host and wait for the real frontend")
        if "shell_id=nanoui-library" not in (success_data / "session/runtime.lock").read_text(encoding="utf-8"):
            raise RuntimeError("library did not commit the successful frontend")
        _, running = invoke(console, "status", success_data, mode)
        if running["state"] != "running":
            raise RuntimeError("library closed the Host after the frontend exited")
    finally:
        invoke(console, "stop", success_data, mode)

    failure_data = root / "command failure data"
    try:
        output = run([
            str(console),
            "library",
            f"--mode={mode}",
            f"--data={failure_data}",
            f"--shell-dir={candidate}",
            "--assets-demo",
        ], expected=1)
        if "CUTRANS_VM_ATTACH_FAIL" not in output:
            raise RuntimeError("library hid the frontend's failure exit code")
        lock = failure_data / "session/runtime.lock"
        if not lock.is_file() or "shell_id=" in lock.read_text(encoding="utf-8"):
            raise RuntimeError("a failed library command committed a Shell selection")
    finally:
        invoke(console, "stop", failure_data, mode)
    print(f"CUTRANS_NANOUI_COMMAND_OK mode={mode} auto_host=1 wait_exit=1 failure_passthrough=1")


def verify(console: Path, executable: Path, pack: Path, mode: str, root: Path, data: Path, default_paths: bool) -> None:
    console = console.resolve()
    executable = executable.resolve()
    pack = pack.resolve()
    root = check_root(root)
    data = check_root(data)
    if root.exists():
        raise RuntimeError(f"NanoUI verification root must be new: {root}")
    if mode not in {"development", "portable", "installed"}:
        raise RuntimeError(f"unsupported verification mode: {mode}")
    claim(root)
    before = hashes(pack)
    if default_paths:
        output = run([str(console), "context", f"--mode={mode}", "--purpose=normal"])
        line = next((line for line in output.splitlines() if line.startswith("CUTRANS_CONTEXT_JSON ")), "")
        if not line:
            raise RuntimeError("portable default context did not report its resolved paths")
        context = json.loads(line.split(" ", 1)[1])
        if context["form"] != mode or canonical_path(Path(context["data_dir"])) != canonical_path(data) or data.exists():
            raise RuntimeError("read-only portable context resolved another root or created user data")
    initial_failure_data = root / "initial failure data"
    committed_failure_data = root / "committed failure data"
    try:
        _, initial_started = invoke(console, "start", initial_failure_data, mode)
        candidate = broken_pack(pack, root / "broken-shell")
        failed_frontend_preserves_lock(executable, candidate, mode, initial_failure_data, False)
        _, running = invoke(console, "status", initial_failure_data, mode)
        if running["state"] != "running" or running["boot"] != initial_started["boot"]:
            raise RuntimeError(f"Host did not survive the rejected NanoUI frontend: {running}")
        invoke(console, "stop", initial_failure_data, mode)
        verify_library_command(console, mode, root, candidate)

        _, started = invoke(console, "start", data, mode)
        lock = data / "session/runtime.lock"
        previous = lock.read_bytes()
        selected_pack = pack if b"shell_id=" in previous and b"shell_id=nanoui-library" not in previous else None
        successful_frontend(executable, mode, data, default_paths, selected_pack)
        committed = lock.read_bytes()
        if b"shell_id=nanoui-library" not in committed:
            raise RuntimeError("a successful NanoUI frontend did not commit its Shell identity")
        _, running = invoke(console, "status", data, mode)
        if running["state"] != "running" or running["boot"] != started["boot"]:
            raise RuntimeError(f"Host did not survive the NanoUI Shell: {running}")
        invoke(console, "stop", data, mode)

        shutil.copytree(data, committed_failure_data)
        _, committed_started = invoke(console, "start", committed_failure_data, mode)
        failed_frontend_preserves_lock(executable, candidate, mode, committed_failure_data, False)
        _, running = invoke(console, "status", committed_failure_data, mode)
        if running["state"] != "running" or running["boot"] != committed_started["boot"]:
            raise RuntimeError(f"Host did not survive the failed NanoUI migration: {running}")
        if hashes(pack) != before or (pack / "data").exists():
            raise RuntimeError("NanoUI verification modified its Shell Pack or stored data inside it")
        print(f"CUTRANS_NANOUI_SELECTION_OK mode={mode} precheck_only_failure=1 commit_after_success=1 default_attach={int(selected_pack is None)}")
        print("CUTRANS_NANOUI_LIBRARY_VERIFY_OK attach=1 host_survives=1 pack_pure=1")
    finally:
        for owned_data in (initial_failure_data, data, committed_failure_data):
            try:
                invoke(console, "stop", owned_data, mode)
            except Exception as error:
                print(f"NanoUI Host cleanup stop: {error}")
        retain(root)


def verify_portable(portable: Path, root: Path) -> None:
    portable = portable.resolve()
    root = check_root(root)
    if root.exists():
        raise RuntimeError(f"portable NanoUI verification root must be new: {root}")
    if (portable / "data").exists():
        raise RuntimeError("portable staging already contains user data")
    claim(root)
    copied = root / "portable"
    try:
        shutil.copytree(portable, copied)
        context_record(copied / "cutrans-context.json", "portable")
        pack = copied / "nanoui-library"
        verify(
            copied / "cutrans_vm.exe",
            pack / "cutrans_library_nanoui.exe",
            pack,
            "portable",
            root / "probe",
            copied / "data",
            default_paths=True,
        )
        if not (copied / "data/session/runtime.lock").is_file():
            raise RuntimeError("the portable frontend did not use the portable root data directory")
        print("CUTRANS_NANOUI_DISTRIBUTION_VERIFY_OK mode=portable default_resolution=readonly explicit_verification_data=1 pack_pure=1")
    finally:
        retain(root)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--distribution", choices=("development", "portable"), default="development")
    parser.add_argument("--root", type=Path)
    args = parser.parse_args()
    if args.distribution == "portable":
        root = args.root or default_root("nanoui-portable")
        verify_portable(OUTPUT / "portable", root)
        return
    root = args.root or default_root("nanoui-library")
    verify(
        OUTPUT / "bin/cutrans_vm.exe",
        OUTPUT / "bin/cutrans_library_nanoui.exe",
        OUTPUT / "nanoui-library",
        "development",
        root,
        root / "data",
        default_paths=False,
    )


if __name__ == "__main__":
    main()
