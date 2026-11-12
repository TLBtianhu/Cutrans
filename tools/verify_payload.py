"""Verify builtin NanoUI payload without legacy Shell executables or Packs."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import time

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from verification_context import context_record
from verification_paths import check_root, claim, default_root, remove, retain
from verify_host import invoke, run
from verify_input import hashes
from verify_same_file import desktop_case, library_case, require, run_role

ROOT = Path(__file__).resolve().parents[1]


def lock_mismatch_case(console: Path, root: Path, evidence: dict) -> None:
    """A default launch must not migrate the locked Shell identity implicitly."""
    data = check_root(root / "desktop data")
    payload = console.parent / "payload/desktop/payload.json"
    original = payload.read_bytes()
    manifest = json.loads(original)
    # Keep the built-in id but change the manifest hash. A default launch must
    # reject this same-id payload replacement; a sibling built-in app switch is
    # tested separately by the library scenario.
    manifest["version"] = "0.1.0+lock-test"
    lock = data / "session/runtime.lock"
    switch_data = check_root(root / "lock switch data")
    try:
        invoke(console, "start", data, "portable")
        locked_before = lock.read_text(encoding="utf-8")
        payload.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        run([str(console), "--mode=portable", f"--data={data}", "--assets-demo"])
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if lock.read_text(encoding="utf-8") != locked_before:
                break
            time.sleep(0.05)
        require(lock.read_text(encoding="utf-8") == locked_before,
            "a default launch silently migrated the locked Shell identity")
        payload.write_bytes(original)
        # The library fixture expects an empty catalog but needs the desktop
        # Shell identity in the lock to exercise the sibling-app switch.
        (switch_data / "session").mkdir(parents=True)
        shutil.copy2(lock, switch_data / "session/runtime.lock")
        shutil.copy2(data / "cutrans-instance.json", switch_data / "cutrans-instance.json")
        output = run([str(console), "library", "--mode=portable", f"--data={switch_data}", "--assets-demo"])
        require("CUTRANS_VM_ATTACH_OK shell=nanoui_library" in output
            and "shell_id=nanoui-library" in (switch_data / "session/runtime.lock").read_text(encoding="utf-8"),
            "a deliberate built-in app switch did not commit the sibling Shell identity")
        evidence["checks"].append("default_launch_never_migrates_a_mismatched_shell_lock")
        evidence["checks"].append("builtin_desktop_to_library_switch_still_commits_the_selected_shell")
    finally:
        payload.write_bytes(original)
        for target in (data, switch_data):
            try:
                invoke(console, "stop", target, "portable")
            except Exception as error:
                evidence[f"lock_cleanup_error_{target.name}"] = repr(error)


def fallback_cases(source: Path, root: Path, evidence: dict) -> None:
    console = source / "cutrans.exe"
    document = check_root(root / "legacy document.cut")
    shutil.copyfile(ROOT / "assets/examples/minimal.cut", document)
    data = check_root(root / "legacy data")
    stopped = False
    try:
        invoke(console, "start", data, "portable")
        text = run_role(console, data, "shell", source / "shell",
            check_root(root / "legacy-role.log"), document)
        require("CUTRANS_SHELL_PRECHECK_OK id=desktop-shell" in text
            and "CUTRANS_ENVIRONMENT_SESSION_OK" in text and "CUTRANS_SHELL_DETACHED" in text,
            "an explicitly selected legacy Shell Pack did not complete its embedded NanoUI scenario")
        digest = hashlib.sha256((source / "shell/shell-pack.json").read_bytes()).hexdigest()
        require(f"shell_manifest_sha256={digest}" in (data / "session/runtime.lock").read_text(encoding="utf-8"),
            "the explicit legacy Pack did not retain its own identity")
        invoke(console, "stop", data, "portable")
        stopped = True
    finally:
        if not stopped:
            try:
                invoke(console, "stop", data, "portable")
            except Exception as error:
                evidence["legacy_cleanup_error"] = repr(error)

    # External payload is absent, but the executable carries its own copy.
    # It must materialize that copy, not fall back to the legacy Shell Pack.
    embedded_only = check_root(root / "embedded-only")
    shutil.copytree(source, embedded_only)
    remove(embedded_only / "payload")
    embedded_data = check_root(root / "embedded payload data")
    embedded_console = embedded_only / "cutrans.exe"
    embedded_stopped = False
    try:
        invoke(embedded_console, "start", embedded_data, "portable")
        text = run_role(embedded_console, embedded_data, "shell", None,
            check_root(root / "embedded-role.log"), None)
        require("CUTRANS_SHELL_ASSETS_OK" in text and "CUTRANS_SHELL_DETACHED" in text,
            "a missing external payload did not use the embedded copy")
        invoke(embedded_console, "stop", embedded_data, "portable")
        embedded_stopped = True
    finally:
        if not embedded_stopped:
            try:
                invoke(embedded_console, "stop", embedded_data, "portable")
            except Exception as error:
                evidence["embedded_cleanup_error"] = repr(error)
    require(not (embedded_only / "payload").exists(),
        "the embedded fallback recreated the external payload directory")
    evidence["checks"].append("missing_external_payload_uses_embedded_copy")

    # The distribution shape that matters: one executable, no payload,
    # context, shell or runtime files at all.
    only_exe = check_root(root / "only-exe")
    only_exe.mkdir()
    shutil.copyfile(console, only_exe / "cutrans.exe")
    only_data = check_root(root / "only-exe data")
    only_console = only_exe / "cutrans.exe"
    only_stopped = False
    try:
        invoke(only_console, "start", only_data, "portable")
        text = run_role(only_console, only_data, "shell", None,
            check_root(root / "only-exe-role.log"), None)
        require("CUTRANS_NANOUI_DESKTOP_OK" in text and "CUTRANS_SHELL_DETACHED" in text,
            "a one-executable distribution did not use its embedded payload/context")
        invoke(only_console, "stop", only_data, "portable")
        only_stopped = True
    finally:
        if not only_stopped:
            try:
                invoke(only_console, "stop", only_data, "portable")
            except Exception as error:
                evidence["only_exe_cleanup_error"] = repr(error)
    require(not (only_exe / "payload").exists() and not (only_exe / "cutrans-context.json").exists(),
        "the one-executable run recreated external payload/context files")
    evidence["checks"].append("one_executable_uses_embedded_context_and_payload")

    # An explicit Shell directory is still authoritative: a missing path must
    # fail instead of silently selecting the embedded copy.
    missing_shell = check_root(root / "missing explicit shell")
    missing_data = check_root(root / "explicit missing data")
    output = run([str(embedded_console), "--role=shell", "--mode=portable",
        f"--data={missing_data}", f"--shell-dir={missing_shell}", "--assets-demo"], expected=1)
    require(("PayloadNotFound" in output or "FileNotFound" in output) and not missing_data.exists(),
        "an explicit missing Shell directory silently fell back to the embedded copy")

    corrupted = check_root(root / "corrupt-payload")
    shutil.copytree(source / "payload/desktop", corrupted)
    (corrupted / "assets/examples/pngtest.png").write_bytes(b"deliberately changed payload")
    corrupt_data = check_root(root / "corrupt data")
    run([str(console), "--role=shell", "--mode=portable", f"--data={corrupt_data}",
        f"--shell-dir={corrupted}", "--assets-demo"], expected=1)
    require(not corrupt_data.exists(), "a corrupt payload reached environment activation or created data")
    evidence["checks"].append("explicit_legacy_identity_and_corrupt_or_explicit_payload_never_implicitly_falls_back")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("payload"))
    args = parser.parse_args()
    require(os.name == "nt", "payload verification requires Windows")
    root = claim(args.root)
    source = (OUTPUT / "portable").resolve()
    require(not (source / "data").exists(), "portable staging already contains user data")
    copied = check_root(root / "payload only")
    shutil.copytree(source, copied)
    for directory in ("runtime", "shell", "nanoui-library", "assets", "config"):
        remove(copied / directory)
    for executable in ("cutrans_vm.exe", "cutrans_vm_host.exe", "cutrans_bootstrap.exe",
            "cutrans_shell.exe", "cutrans_diag.exe"):
        (copied / executable).unlink()
    if (copied / "wgpu_native.dll").exists():
        (copied / "wgpu_native.dll").unlink()
    console = copied / "cutrans.exe"
    context_record(copied / "cutrans-context.json", "portable")
    before = hashes(copied)
    source_before = hashes(source)
    evidence = {"format": "cutrans-payload-verification/1", "root": str(root),
        "legacy_runtime_and_shell_removed": True, "artifact_hashes": before, "checks": [], "passed": False}
    try:
        desktop_case(console, root, evidence)
        lock_mismatch_case(console, root, evidence)
        library_case(console, copied / "payload/nanoui-library", root, evidence)
        evidence["checks"].append("builtin_desktop_and_library_without_runtime_or_legacy_shell_files")
        fallback_cases(source, root, evidence)
        require(hashes(copied) == before and hashes(source) == source_before,
            "payload verification modified an application or Pack")
        require(not (copied / "data").exists(), "payload verification polluted portable staging")
        evidence["passed"] = True
        print("CUTRANS_PAYLOAD_VERIFY_OK legacy_exe=0 legacy_pack=0 builtin=1 explicit_fallback=1 embedded_fallback=1 single_exe=1 no_legacy_fallback=1 pack_pure=1")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        (root / "payload.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)
        print(f"Payload evidence retained: {root}")


if __name__ == "__main__":
    main()
