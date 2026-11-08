"""Verify the independently loaded runtime from the portable distribution."""

from __future__ import annotations

import hashlib
import json
import shutil
from pathlib import Path

import automation_process

ROOT = Path(__file__).resolve().parents[1]
from build_paths import OUTPUT
from verification_paths import default_root, claim, retain, remove
from verification_context import command_args, copy_installed_context


def hashes(root: Path) -> dict[str, str]:
    return {
        path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in root.rglob("*")
        if path.is_file()
    }


def run(command: list[str], expected: int = 0) -> str:
    result = automation_process.run(command_args(command), capture_output=True, text=True)
    output = result.stdout + result.stderr
    print(output, end="")
    if result.returncode != expected:
        raise RuntimeError(f"unexpected runtime bootstrap exit code {result.returncode}, expected {expected}")
    return output


def reject_candidate(bootstrap: Path, candidate: Path, data: Path, expected_error: str) -> None:
    lock = data / "session/runtime.lock"
    before = lock.read_bytes()
    output = run([
        str(bootstrap),
        f"--runtime={candidate}",
        "--mode=portable",
        "--diag",
        f"--data={data}",
    ], expected=1)
    if expected_error not in output:
        raise RuntimeError(f"runtime candidate failed for an unexpected reason; wanted {expected_error}")
    if lock.read_bytes() != before:
        raise RuntimeError(f"{expected_error} changed the committed runtime selection")


def main() -> None:
    portable = (OUTPUT / "portable").resolve()
    bootstrap = portable / "cutrans_bootstrap.exe"
    runtime = portable / "runtime"
    if not bootstrap.is_file() or not (runtime / "runtime-pack.json").is_file():
        raise RuntimeError("portable runtime is missing; run zig build portable first")
    if (runtime / "wgpu_native.dll").exists():
        raise RuntimeError("headless runtime unexpectedly contains wgpu")
    if (portable / "data").exists() or (runtime / "data").exists():
        raise RuntimeError("runtime staging already contains user data")
    root = default_root("runtime-user")
    if root.exists():
        raise RuntimeError(f"runtime verification root must be new: {root}")
    claim(root)
    before = hashes(runtime)

    output = run([str(bootstrap), "--mode=portable", "--diag", f"--data={root / 'portable data'}"])
    if "CUTRANS_RUNTIME_OK" not in output:
        raise RuntimeError("portable runtime diagnostic did not report success")
    data = root / "portable data"
    lock = data / "session/runtime.lock"
    initial_lock = lock.read_text(encoding="utf-8")
    if "C:\\" in initial_lock or root.as_posix() in initial_lock:
        raise RuntimeError("selection lock leaked a host path")
    alternate = root / "alternate-runtime"
    shutil.copytree(runtime, alternate)
    manifest_path = alternate / "runtime-pack.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["version"] = "0.1.0-test"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    run([str(bootstrap), f"--runtime={alternate}", "--mode=portable", "--diag", f"--data={data}"])
    migrated_lock = lock.read_text(encoding="utf-8")
    if "0.1.0-test" not in migrated_lock or migrated_lock == initial_lock:
        raise RuntimeError("explicit runtime migration did not update the selection lock")
    output = run([str(bootstrap), "--mode=portable", "--diag", f"--data={data}"], expected=1)
    if "RuntimeLockMismatch" not in output or lock.read_text(encoding="utf-8") != migrated_lock:
        raise RuntimeError("default runtime drift bypassed the selection lock")
    run([str(bootstrap), f"--runtime={runtime}", "--mode=portable", "--diag", f"--data={data}"])
    if lock.read_text(encoding="utf-8") != initial_lock:
        raise RuntimeError("explicit rollback did not restore the original selection")
    print("CUTRANS_RUNTIME_LOCK_OK migrate=1 reject_drift=1 rollback=1")

    missing = root / "missing-runtime"
    shutil.copytree(runtime, missing)
    (missing / "config/startup.ccb").unlink()
    reject_candidate(bootstrap, missing, data, "FileNotFound")

    incompatible = root / "incompatible-runtime"
    shutil.copytree(runtime, incompatible)
    incompatible_manifest_path = incompatible / "runtime-pack.json"
    incompatible_manifest = json.loads(incompatible_manifest_path.read_text(encoding="utf-8"))
    incompatible_manifest["abi"] = "incompatible-os"
    incompatible_manifest_path.write_text(json.dumps(incompatible_manifest, indent=2) + "\n", encoding="utf-8")
    reject_candidate(bootstrap, incompatible, data, "IncompatibleRuntimeAbi")

    failed_handshake = root / "handshake-runtime"
    shutil.copytree(runtime, failed_handshake)
    handshake_manifest_path = failed_handshake / "runtime-pack.json"
    handshake_manifest = json.loads(handshake_manifest_path.read_text(encoding="utf-8"))
    handshake_manifest["required_capabilities"].append("test.capability.unavailable")
    handshake_manifest_path.write_text(json.dumps(handshake_manifest, indent=2) + "\n", encoding="utf-8")
    reject_candidate(bootstrap, failed_handshake, data, "RuntimeCapabilityMismatch")

    create_data = root / "create-failure-data"
    shutil.copytree(data, create_data)
    (create_data / "documents/history.txt").write_text("cutrans_history=999\n", encoding="utf-8")
    reject_candidate(bootstrap, runtime, create_data, "RuntimeCreateFailed")

    install = root / "relocatable"
    (install / "app").mkdir(parents=True)
    shutil.copy2(bootstrap, install / "app/cutrans_bootstrap.exe")
    copy_installed_context(install / "app")
    shutil.copytree(runtime, install / "runtime-envs/default")
    relocated_bootstrap = install / "app/cutrans_bootstrap.exe"
    output = run([str(relocated_bootstrap), "--mode=installed", "--diag", f"--data={install / 'data'}"])
    relocated_lock = install / "data/session/runtime.lock"
    if "CUTRANS_RUNTIME_OK" not in output or relocated_lock.read_text(encoding="utf-8") != initial_lock:
        raise RuntimeError("single-root runtime activation failed before relocation")
    moved = root / "relocated install"
    install.rename(moved)
    moved_bootstrap = moved / "app/cutrans_bootstrap.exe"
    output = run([str(moved_bootstrap), "--mode=installed", "--diag", f"--data={moved / 'data'}"])
    moved_lock = moved / "data/session/runtime.lock"
    if "CUTRANS_RUNTIME_OK" not in output or moved_lock.read_text(encoding="utf-8") != initial_lock:
        raise RuntimeError("runtime could not be reactivated after moving the installation root")
    if install.exists() or (moved / "app/data").exists():
        raise RuntimeError("relocation used the old root or an application-local data directory")
    print("CUTRANS_RUNTIME_ACTIVATION_OK missing=1 abi=1 create=1 handshake=1 relocate=1")

    document = root / "external document.cut"
    shutil.copyfile(ROOT / "assets/examples/minimal.cut", document)
    original_document = document.read_bytes()
    output = run([str(bootstrap), "--mode=portable", "--headless", f"--data={root / 'external data'}", "--open", str(document)])
    if "CUTRANS_RUNTIME_OPEN_OK" not in output:
        raise RuntimeError("portable runtime did not open and restore the absolute document")
    saved_document = (root / "external data/documents/session.cut").read_text(encoding="utf-8")
    if (document.read_bytes() != original_document or not saved_document.startswith("version=3\n")
        or "value:0.8" not in saved_document or str(document) in saved_document):
        raise RuntimeError("external document changed or its Session copy lost the document content")
    print("CUTRANS_VNE_URI_OK version=3 host_path=0 original_unchanged=1 session_copy=1")

    tampered = root / "tampered-runtime"
    shutil.copytree(runtime, tampered)
    sample = tampered / "assets/examples/minimal.cut"
    sample.write_bytes(sample.read_bytes() + b" ")
    tampered_data = root / "tampered-data"
    output = run([str(bootstrap), f"--runtime={tampered}", "--diag", f"--data={tampered_data}"], expected=1)
    if "RuntimeFileSizeMismatch" not in output or tampered_data.exists():
        raise RuntimeError("tampered runtime was loaded or created user data")
    if hashes(runtime) != before or (portable / "data").exists() or (runtime / "data").exists():
        raise RuntimeError("runtime verification polluted portable staging")
    print("CUTRANS_RUNTIME_VERIFY_OK portable=1 absolute_open=1 tamper_rejected=1 legacy_gpu_free=1")
    retain(root)


if __name__ == "__main__":
    main()
