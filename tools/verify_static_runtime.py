"""Verify the built-in Runtime without a Runtime directory in an isolated copy."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import sys

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from verification_context import context_record
from verification_paths import check_root, claim, default_root, remove, retain
from verify_host import run
from verify_input import hashes
from verify_same_file import desktop_case, library_case, require


def provider_case(console: Path, dynamic_console: Path, root: Path, evidence: dict) -> None:
    data = check_root(root / "provider data")
    output = run([str(console), "--diag", "--mode=portable", f"--data={data}"])
    require("CUTRANS_RUNTIME_OK" in output and "provider=static" in output and "files=0" in output,
        "the built-in Runtime did not complete save and restore without a Runtime directory")
    dynamic_runtime = dynamic_console.parent / "runtime"
    output = run([str(dynamic_console), "--diag", "--mode=portable", f"--data={data}",
        f"--runtime={dynamic_runtime}"])
    require("CUTRANS_RUNTIME_OK" in output and "provider=dynamic" in output,
        "an explicit Runtime Pack did not retain the dynamic provider")
    output = run([str(console), "--diag", "--mode=portable", f"--data={data}"], expected=1)
    require("RuntimeLockMismatch" in output, "a different Runtime provider silently replaced the locked identity")
    output = run([str(console), "--diag", "--mode=portable", f"--data={data}", "--runtime=builtin"])
    require("CUTRANS_RUNTIME_OK" in output and "provider=static" in output,
        "explicit builtin selection did not migrate the Runtime identity")
    evidence["checks"].append("static_save_restore_dynamic_fallback_lock_mismatch_and_explicit_builtin_migration")

    missing_data = check_root(root / "missing dynamic data")
    missing_runtime = check_root(root / "missing-runtime")
    run([str(console), "start", "--mode=portable", f"--data={missing_data}",
        f"--runtime={missing_runtime}"], expected=1)
    require(not missing_data.exists(), "a missing explicit dynamic Pack fell back to static or created data")
    rejected_data = check_root(root / "legacy builtin data")
    output = run([str(dynamic_console.parent / "cutrans_vm.exe"), "start", "--mode=portable",
        f"--data={rejected_data}", "--runtime=builtin"], expected=1)
    require("StaticRuntimeUnavailable" in output and not rejected_data.exists(),
        "the legacy dynamic entry unexpectedly accepted the builtin provider")
    evidence["checks"].append("explicit_dynamic_missing_does_not_fallback_and_legacy_builtin_is_rejected")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("static-runtime"))
    args = parser.parse_args()
    require(os.name == "nt", "static Runtime verification requires Windows")
    root = claim(args.root)
    source = (OUTPUT / "portable").resolve()
    require(not (source / "data").exists(), "portable staging already contains user data")
    copied = check_root(root / "static portable")
    shutil.copytree(source, copied)
    remove(copied / "runtime")
    require(not (copied / "runtime").exists(), "the isolated Runtime directory was not removed")
    console = copied / "cutrans.exe"
    context_record(copied / "cutrans-context.json", "portable")
    before = hashes(copied)
    source_before = hashes(source)
    evidence = {"format": "cutrans-static-runtime-verification/1", "root": str(root),
        "runtime_directory_removed": True, "artifact_hashes": before, "checks": [], "passed": False}
    try:
        provider_case(console, source / "cutrans.exe", root, evidence)
        desktop_case(console, root, evidence)
        library_case(console, copied / "payload/nanoui-library", root, evidence)
        require(hashes(copied) == before and hashes(source) == source_before,
            "static Runtime verification modified an application or Pack")
        require(not (copied / "runtime").exists() and not (copied / "data").exists(),
            "static Runtime verification recreated Runtime files or polluted portable data")
        evidence["passed"] = True
        print("CUTRANS_STATIC_RUNTIME_VERIFY_OK runtime_dir=0 host=1 shell=1 library=1 restore=1 dynamic_fallback=1 explicit_migration=1 pack_pure=1")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        (root / "static-runtime.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)
        print(f"Static Runtime evidence retained: {root}")


if __name__ == "__main__":
    main()
