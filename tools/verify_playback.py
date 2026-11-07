"""Drive a distributed Runtime playback pump with its real monotonic clock."""

from __future__ import annotations

import argparse
import ctypes
import shutil
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True

from verify_input import ABI_VERSION, ByteSlice, Config, hashes, run, string_slice

ROOT = Path(__file__).resolve().parents[1]
from build_paths import OUTPUT
from verification_paths import default_root, claim, retain, remove, check_root
from verification_context import mark_data


class PlaybackReport(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("active", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("cursor", ctypes.c_int64),
        ("frames", ctypes.c_int64),
        ("offer_count", ctypes.c_uint64),
        ("underflow_count", ctypes.c_uint64),
        ("present_count", ctypes.c_uint64),
        ("last_t", ctypes.c_int64),
    ]


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
    if "CUTRANS_PLAYBACK_OK" not in output:
        raise RuntimeError("isolated Runtime playback probe did not report success")


def _verify(runtime_dir: Path, bootstrap: Path, mode: str, root: Path) -> None:
    runtime_dir = runtime_dir.resolve()
    bootstrap = bootstrap.resolve()
    root = check_root(root)
    if root.exists():
        raise RuntimeError(f"playback verification root must be new: {root}")
    if mode not in {"portable", "installed"}:
        raise RuntimeError(f"unsupported verification mode: {mode}")
    if mode == "portable" and (runtime_dir.parent / "data").exists():
        raise RuntimeError("portable staging already contains user data")
    claim(root)
    before = hashes(runtime_dir)
    data_dir = root / "playback data"
    library = ctypes.WinDLL(str(runtime_dir / "cutrans_vm_runtime.dll"))
    library.cutrans_vm_create.argtypes = [ctypes.POINTER(Config), ctypes.POINTER(ctypes.c_void_p)]
    library.cutrans_vm_create.restype = ctypes.c_int32
    library.cutrans_vm_destroy.argtypes = [ctypes.c_void_p]
    library.cutrans_vm_destroy.restype = None
    library.cutrans_vm_command.argtypes = [ctypes.c_void_p, ByteSlice, ByteSlice]
    library.cutrans_vm_command.restype = ctypes.c_int32
    library.cutrans_vm_pump.argtypes = [ctypes.c_void_p]
    library.cutrans_vm_pump.restype = ctypes.c_int32
    library.cutrans_vm_playback_report.argtypes = [ctypes.c_void_p, ctypes.POINTER(PlaybackReport)]
    library.cutrans_vm_playback_report.restype = ctypes.c_int32
    resource, resource_storage = string_slice(str(runtime_dir))
    data, data_storage = string_slice(str(data_dir))
    mark_data(data_dir, mode, runtime_dir)
    config = Config(ctypes.sizeof(Config), ABI_VERSION, 1 if mode == "portable" else 2, 0, resource, data)
    handle = ctypes.c_void_p()
    if library.cutrans_vm_create(ctypes.byref(config), ctypes.byref(handle)) != 0 or not handle.value:
        raise RuntimeError("could not create the distributed Runtime")

    def command(name: str, argument: str | None = None, expected: int = 0) -> None:
        name_slice, name_storage = string_slice(name)
        if argument is None:
            argument_slice = ByteSlice()
            argument_storage = None
        else:
            argument_slice, argument_storage = string_slice(argument)
        status = library.cutrans_vm_command(handle, name_slice, argument_slice)
        if status != expected:
            raise RuntimeError(f"{name} returned {status}, expected {expected}")

    def report() -> PlaybackReport:
        value = PlaybackReport()
        if library.cutrans_vm_playback_report(handle, ctypes.byref(value)) != 0:
            raise RuntimeError("could not read playback state")
        return value

    try:
        initial = report()
        if initial.active or initial.offer_count or initial.last_t != -1:
            raise RuntimeError("fresh Runtime has unexpected playback state")
        command("playback.start", "0", expected=3)
        command("playback.start", "4", expected=1)
        for _ in range(80):
            if library.cutrans_vm_pump(handle) != 0:
                raise RuntimeError("real-clock playback pump failed")
            if not report().active:
                break
            time.sleep(0.02)
        else:
            raise RuntimeError("playback did not finish within the real-clock deadline budget")
        finished = report()
        if finished.cursor != 4 or finished.frames != 4 or finished.offer_count != 4 or finished.underflow_count != 0 or finished.present_count != 0 or finished.last_t != 3:
            raise RuntimeError(f"unexpected playback result: cursor={finished.cursor} frames={finished.frames} offers={finished.offer_count} underflow={finished.underflow_count} present={finished.present_count} last_t={finished.last_t}")
        command("playback.status")
        command("playback.stop", expected=5)
        command("playback.start", "4", expected=1)
        command("playback.stop")
        if report().active or report().offer_count != 4:
            raise RuntimeError("playback stop did not preserve the correct state")
        if library.cutrans_vm_pump(handle) != 0 or report().offer_count != 4:
            raise RuntimeError("stopped playback advanced on a later pump")
    finally:
        library.cutrans_vm_destroy(handle)
    if hashes(runtime_dir) != before or (runtime_dir / "data").exists():
        raise RuntimeError("playback verification modified the Runtime Pack")
    if mode == "portable" and (runtime_dir.parent / "data").exists():
        raise RuntimeError("playback verification polluted portable staging")
    retain(root)
    print("CUTRANS_PLAYBACK_OK frames=4 offers=4 underflow=0 restart_stop=1 os_injection=0")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-dir", type=Path, default=OUTPUT / "portable/runtime")
    parser.add_argument("--bootstrap", type=Path, default=OUTPUT / "portable/cutrans_bootstrap.exe")
    parser.add_argument("--mode", choices=("portable", "installed"), default="portable")
    parser.add_argument("--root", type=Path, default=default_root("playback-user"))
    args = parser.parse_args()
    _verify(args.runtime_dir, args.bootstrap, args.mode, args.root)


if __name__ == "__main__":
    main()
