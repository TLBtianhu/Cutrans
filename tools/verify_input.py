"""Verify semantic input recording and replay through a distributed Runtime DLL."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import shutil
import sys
from pathlib import Path

import automation_process

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
from build_paths import OUTPUT
from verification_paths import default_root, claim, retain, remove, check_root
from verification_context import command_args, mark_data
from product import identity

ABI_VERSION = identity()["host_api"]


class ByteSlice(ctypes.Structure):
    _fields_ = [("ptr", ctypes.c_void_p), ("len", ctypes.c_size_t)]


class Config(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("mode", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("resource_dir", ByteSlice),
        ("data_dir", ByteSlice),
    ]


class InputEvent(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("kind", ctypes.c_uint8),
        ("action", ctypes.c_uint8),
        ("code", ctypes.c_uint16),
        ("mods", ctypes.c_uint8),
        ("reserved", ctypes.c_uint8 * 3),
        ("context", ctypes.c_uint32),
        ("x", ctypes.c_int32),
        ("y", ctypes.c_int32),
        ("text", ByteSlice),
    ]


class InputRecordReport(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("event_count", ctypes.c_uint64),
        ("time_ns", ctypes.c_int64),
    ]


def string_slice(value: str) -> tuple[ByteSlice, ctypes.Array[ctypes.c_char]]:
    encoded = value.encode("utf-8")
    storage = ctypes.create_string_buffer(encoded)
    return ByteSlice(ctypes.cast(storage, ctypes.c_void_p), len(encoded)), storage


def event(kind: int, action: int = 0, code: int = 0, mods: int = 0, context: int = 0, x: int = 0, y: int = 0, text: str | None = None) -> tuple[InputEvent, ctypes.Array[ctypes.c_char] | None]:
    result = InputEvent(
        struct_size=ctypes.sizeof(InputEvent),
        abi_version=ABI_VERSION,
        kind=kind,
        action=action,
        code=code,
        mods=mods,
        context=context,
        x=x,
        y=y,
    )
    storage = None
    if text is not None:
        result.text, storage = string_slice(text)
    return result, storage


def run(command: list[str], expected: int = 0) -> str:
    result = automation_process.run(command_args(command), capture_output=True, text=True)
    output = result.stdout + result.stderr
    print(output, end="")
    if result.returncode != expected:
        raise RuntimeError(f"unexpected exit code {result.returncode}, expected {expected}")
    return output


def hashes(root: Path) -> dict[str, str]:
    return {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in root.rglob("*") if path.is_file()}


def verify(runtime_dir: Path, bootstrap: Path, mode: str, root: Path) -> None:
    output = run([
        sys.executable,
        str(Path(__file__).resolve()),
        "--runtime-dir",
        str(runtime_dir.resolve()),
        "--bootstrap",
        str(bootstrap.resolve()),
        "--mode",
        mode,
        "--root",
        str(check_root(root)),
    ])
    if "CUTRANS_INPUT_BRIDGE_OK" not in output:
        raise RuntimeError("isolated Runtime input probe did not report success")


def _verify(runtime_dir: Path, bootstrap: Path, mode: str, root: Path) -> None:
    runtime_dir = runtime_dir.resolve()
    bootstrap = bootstrap.resolve()
    root = check_root(root)
    if root.exists():
        raise RuntimeError(f"input verification root must be new: {root}")
    manifest = json.loads((runtime_dir / "runtime-pack.json").read_text(encoding="utf-8"))
    if manifest["host_api"] != ABI_VERSION:
        raise RuntimeError("input bridge requires the current native ABI")
    if mode not in {"portable", "installed"}:
        raise RuntimeError(f"unsupported verification mode: {mode}")
    if mode == "portable" and (runtime_dir.parent / "data").exists():
        raise RuntimeError("portable staging already contains user data")
    claim(root)
    before = hashes(runtime_dir)
    record_data = root / "record data"
    replay_data = root / "replay data"
    library = ctypes.WinDLL(str(runtime_dir / "cutrans_vm_runtime.dll"))
    library.cutrans_vm_abi_version.restype = ctypes.c_uint32
    if library.cutrans_vm_abi_version() != ABI_VERSION:
        raise RuntimeError("distributed Runtime ABI does not match the input bridge")
    library.cutrans_vm_create.argtypes = [ctypes.POINTER(Config), ctypes.POINTER(ctypes.c_void_p)]
    library.cutrans_vm_create.restype = ctypes.c_int32
    library.cutrans_vm_destroy.argtypes = [ctypes.c_void_p]
    library.cutrans_vm_destroy.restype = None
    library.cutrans_vm_input_begin.argtypes = [ctypes.c_void_p, ByteSlice]
    library.cutrans_vm_input_begin.restype = ctypes.c_int32
    library.cutrans_vm_input_push.argtypes = [ctypes.c_void_p, ctypes.POINTER(InputEvent), ctypes.POINTER(ctypes.c_uint64)]
    library.cutrans_vm_input_push.restype = ctypes.c_int32
    library.cutrans_vm_input_flush.argtypes = [ctypes.c_void_p]
    library.cutrans_vm_input_flush.restype = ctypes.c_int32
    library.cutrans_vm_input_end.argtypes = [ctypes.c_void_p, ctypes.POINTER(InputRecordReport)]
    library.cutrans_vm_input_end.restype = ctypes.c_int32
    resource, resource_storage = string_slice(str(runtime_dir))
    data, data_storage = string_slice(str(record_data))
    mark_data(record_data, mode, runtime_dir)
    config = Config(ctypes.sizeof(Config), ABI_VERSION, 1 if mode == "portable" else 2, 0, resource, data)
    handle = ctypes.c_void_p()
    if library.cutrans_vm_create(ctypes.byref(config), ctypes.byref(handle)) != 0 or not handle.value:
        raise RuntimeError("could not create the distributed Runtime")
    try:
        target, target_storage = string_slice("session://input/bridge.cvr")
        readonly, readonly_storage = string_slice("pack://input/forbidden.cvr")
        if library.cutrans_vm_input_begin(handle, readonly) == 0:
            raise RuntimeError("a read-only Pack accepted an input recording")
        if library.cutrans_vm_input_begin(handle, target) != 0:
            raise RuntimeError("could not start semantic input recording")
        if library.cutrans_vm_input_begin(handle, target) == 0:
            raise RuntimeError("duplicate recording start was accepted")
        invalid, invalid_storage = event(255)
        if library.cutrans_vm_input_push(handle, ctypes.byref(invalid), None) != 3:
            raise RuntimeError("an invalid semantic event kind was not rejected")
        serial = ctypes.c_uint64()
        for index in range(40):
            item, item_storage = event(0, x=index, y=24)
            if library.cutrans_vm_input_push(handle, ctypes.byref(item), ctypes.byref(serial)) != 0 or serial.value != index + 1:
                raise RuntimeError(f"pointer event {index + 1} failed or received the wrong serial")
        for item, item_storage in [
            event(1, action=2, code=1, x=24, y=32),
            event(2, action=1, code=1, x=24, y=32),
            event(3, action=3, code=257, mods=3),
            event(5, text="你\n好,Cutrans"),
            event(6, x=1),
            event(3, action=2, code=90, mods=2),
            event(3, action=2, code=73, mods=2),
            event(3, action=2, code=90, mods=2),
            event(3, action=3, code=89, mods=2),
            event(3, action=2, code=90, mods=2, context=1),
        ]:
            if library.cutrans_vm_input_push(handle, ctypes.byref(item), ctypes.byref(serial)) != 0:
                raise RuntimeError("semantic button, key, text, focus, or action event failed")
        if serial.value != 50 or library.cutrans_vm_input_flush(handle) != 0:
            raise RuntimeError("live events were not consumed and flushed")
        report = InputRecordReport()
        if library.cutrans_vm_input_end(handle, ctypes.byref(report)) != 0:
            raise RuntimeError("could not finish input recording")
        if report.event_count != 50 or report.time_ns < 0:
            raise RuntimeError("recording report has the wrong event count or time")
        if library.cutrans_vm_input_end(handle, None) == 0:
            raise RuntimeError("duplicate recording finish was accepted")
    finally:
        library.cutrans_vm_destroy(handle)
    recorded = record_data / "input/bridge.cvr"
    recorded_bytes = recorded.read_bytes()
    text = recorded_bytes.decode("utf-8")
    if not text.startswith("cutrans_input_replay=3\nclock=logical\nbaseline="):
        raise RuntimeError("recording did not use the v3 semantic log")
    if str(record_data) in text or record_data.as_posix() in text or "你\n好,Cutrans" in text:
        raise RuntimeError("recording leaked a host path or unencoded text")
    if text.count("event=") != 50:
        raise RuntimeError("recording lost events")
    if "editor.invert.add,ok" not in text or "history.undo,invalid_state" not in text or "history.undo,suppressed" not in text:
        raise RuntimeError("recording did not preserve command outcomes and text-context suppression")
    expectation = next(line for line in text.splitlines() if line.startswith("expect="))
    if not expectation.endswith(",1,1"):
        raise RuntimeError("recording did not preserve the final History cursor")
    expected_fingerprint = expectation.split(",")[0].split("=")[1]
    mark_data(replay_data, mode, runtime_dir)
    replay_fixture = replay_data / "input/bridge.cvr"
    replay_fixture.parent.mkdir(parents=True)
    replay_fixture.write_bytes(recorded_bytes)
    output = run([str(bootstrap), f"--mode={mode}", f"--data={replay_data}", "--replay=session://input/bridge.cvr"])
    if "kind=1 events=50 input_events=50" not in output or f"fingerprint={expected_fingerprint}" not in output or "history=1" not in output or "history_cursor=1" not in output:
        raise RuntimeError("a fresh Runtime did not reproduce the recorded document and History state")
    console = bootstrap.parent / "cutrans_vm.exe"
    shell = bootstrap.parent / "cutrans_shell.exe"
    reject_data = root / "reject shell data"
    run([str(console), "start", f"--mode={mode}", f"--data={reject_data}"])
    try:
        output = run([str(bootstrap), f"--mode={mode}", f"--data={reject_data}", "--record-input=pack://input/forbidden.cvr"])
        if "CUTRANS_VM_ATTACH_ACCEPTED shell=desktop" not in output or "HostAlreadyRunning" in output:
            raise RuntimeError("the default entry created a second Runtime instead of attaching the desktop")
        output = run([str(shell), f"--mode={mode}", f"--data={reject_data}", "--record-input=pack://input/forbidden.cvr"], expected=1)
        if "CUTRANS_INPUT_BEGIN_FAIL" not in output:
            raise RuntimeError("the attached desktop did not forward the recording destination to the VM")
        if "shell_id=" in (reject_data / "session/runtime.lock").read_text(encoding="utf-8"):
            raise RuntimeError("a read-only recording failure committed a Shell selection")
        print("CUTRANS_DEFAULT_ENTRY_OK attach=1 second_runtime=0 readonly=1")
    finally:
        run([str(console), "stop", f"--mode={mode}", f"--data={reject_data}"])
    run([str(bootstrap), "--headless", "--record-input=session://input/conflict.cvr"], expected=1)
    if hashes(runtime_dir) != before or (runtime_dir / "data").exists():
        raise RuntimeError("input verification modified the Runtime Pack")
    if mode == "portable" and (runtime_dir.parent / "data").exists():
        raise RuntimeError("input verification polluted portable staging")
    retain(root)
    print("CUTRANS_INPUT_ACTION_OK insert=1 undo=1 redo=1 suppressed=1")
    print("CUTRANS_INPUT_BRIDGE_OK events=50 replay=1 version=3 os_injection=0")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-dir", type=Path, default=OUTPUT / "portable/runtime")
    parser.add_argument("--bootstrap", type=Path, default=OUTPUT / "portable/cutrans_bootstrap.exe")
    parser.add_argument("--mode", choices=("portable", "installed"), default="portable")
    parser.add_argument("--root", type=Path, default=default_root("input-user"))
    args = parser.parse_args()
    _verify(args.runtime_dir, args.bootstrap, args.mode, args.root)


if __name__ == "__main__":
    main()
