"""Verify the builtin NanoUI payload of the single-process environment."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import sys

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from environment_harness import desktop_case, library_case, require, run, run_app
from verification_context import context_record
from verification_paths import check_root, claim, default_root, remove, retain
from verify_input import hashes


def lock_mismatch_case(console: Path, root: Path, evidence: dict) -> None:
    """A default launch must not migrate the locked App identity implicitly."""
    data = check_root(root / "desktop data")
    payload = console.parent / "payload/desktop/payload.json"
    original = payload.read_bytes()
    manifest = json.loads(original)
    # Keep the built-in id but change the manifest hash. A default launch must
    # reject this same-id payload replacement; a sibling built-in App switch is
    # tested separately below.
    manifest["version"] = "0.1.0+lock-test"
    lock = data / "session/runtime.lock"
    switch_data = check_root(root / "lock switch data")
    try:
        locked_before = lock.read_text(encoding="utf-8")
        payload.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        output = run([str(console), "--mode=portable", f"--data={data}", "--assets-demo"], expected=1)
        require("ShellLockMismatch" in output and lock.read_text(encoding="utf-8") == locked_before,
            "a default launch silently migrated the locked App identity")
        payload.write_bytes(original)
        # The library fixture expects an empty catalog but needs the desktop
        # identity in the lock to exercise the sibling-App switch.
        (switch_data / "session").mkdir(parents=True)
        shutil.copy2(lock, switch_data / "session/runtime.lock")
        shutil.copy2(data / "cutrans-instance.json", switch_data / "cutrans-instance.json")
        output = run_app(console, switch_data, check_root(root / "lock-switch.log"), flavor="library")
        require("CUTRANS_NANOUI_LIBRARY_OK" in output
            and "shell_id=nanoui-library" in (switch_data / "session/runtime.lock").read_text(encoding="utf-8"),
            "a deliberate built-in App switch did not commit the sibling identity")
        evidence["checks"].append("default_launch_never_migrates_a_mismatched_app_lock")
        evidence["checks"].append("builtin_desktop_to_library_switch_still_commits_the_selected_app")
    finally:
        payload.write_bytes(original)


def fallback_cases(source: Path, root: Path, evidence: dict) -> None:
    console = source / "cutrans.exe"
    # External payload is absent, but the executable carries its own copy.
    embedded_only = check_root(root / "embedded-only")
    shutil.copytree(source, embedded_only)
    remove(embedded_only / "payload")
    text = run_app(embedded_only / "cutrans.exe", check_root(root / "embedded payload data"),
        check_root(root / "embedded.log"))
    require("CUTRANS_SHELL_ASSETS_OK" in text and "CUTRANS_ENVIRONMENT_STOPPED" in text,
        "a missing external payload did not use the embedded copy")
    require(not (embedded_only / "payload").exists(), "the embedded fallback recreated the external payload directory")
    evidence["checks"].append("missing_external_payload_uses_embedded_copy")

    # The distribution shape that matters: one executable and nothing else.
    only_exe = check_root(root / "only-exe")
    only_exe.mkdir()
    shutil.copyfile(console, only_exe / "cutrans.exe")
    text = run_app(only_exe / "cutrans.exe", check_root(root / "only-exe data"), check_root(root / "only-exe.log"))
    require("CUTRANS_NANOUI_DESKTOP_OK" in text and "CUTRANS_ENVIRONMENT_STOPPED" in text,
        "a one-executable distribution did not use its embedded payload/context")
    require(not (only_exe / "payload").exists() and not (only_exe / "cutrans-context.json").exists(),
        "the one-executable run recreated external payload/context files")
    evidence["checks"].append("one_executable_uses_embedded_context_and_payload")

    # An explicit payload directory is authoritative: a missing path must fail
    # instead of silently selecting the embedded copy.
    missing_shell = check_root(root / "missing explicit payload")
    missing_data = check_root(root / "explicit missing data")
    output = run([str(embedded_only / "cutrans.exe"), "--mode=portable", f"--data={missing_data}",
        f"--shell-dir={missing_shell}", "--assets-demo"], expected=1)
    require(("PayloadNotFound" in output or "FileNotFound" in output) and not missing_data.exists(),
        "an explicit missing payload directory silently fell back to the embedded copy")

    corrupted = check_root(root / "corrupt-payload")
    shutil.copytree(source / "payload/desktop", corrupted)
    (corrupted / "assets/examples/pngtest.png").write_bytes(b"deliberately changed payload")
    corrupt_data = check_root(root / "corrupt data")
    run([str(console), "--mode=portable", f"--data={corrupt_data}", f"--shell-dir={corrupted}", "--assets-demo"], expected=1)
    require(not corrupt_data.exists(), "a corrupt payload reached environment activation or created data")
    evidence["checks"].append("corrupt_or_explicit_missing_payload_never_implicitly_falls_back")


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
    for directory in ("runtime", "assets", "config"):
        remove(copied / directory)
    for executable in ("cutrans_bootstrap.exe", "cutrans_diag.exe"):
        (copied / executable).unlink()
    console = copied / "cutrans.exe"
    context_record(copied / "cutrans-context.json", "portable")
    before = hashes(copied)
    source_before = hashes(source)
    evidence = {"format": "cutrans-payload-verification/2", "root": str(root),
        "runtime_and_tools_removed": True, "artifact_hashes": before, "checks": [], "passed": False}
    try:
        desktop_case(console, root, evidence)
        lock_mismatch_case(console, root, evidence)
        library_case(console, copied / "payload/nanoui-library", root, evidence)
        evidence["checks"].append("builtin_desktop_and_library_without_runtime_pack_or_tool_executables")
        fallback_cases(source, root, evidence)
        require(hashes(copied) == before and hashes(source) == source_before,
            "payload verification modified an application or Pack")
        require(not (copied / "data").exists(), "payload verification polluted portable staging")
        evidence["passed"] = True
        print("CUTRANS_PAYLOAD_VERIFY_OK single_process=1 builtin=1 lock_guard=1 sibling_switch=1 embedded_fallback=1 single_exe=1 no_implicit_fallback=1 pack_pure=1")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        (root / "payload.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)
        print(f"Payload evidence retained: {root}")


if __name__ == "__main__":
    main()
