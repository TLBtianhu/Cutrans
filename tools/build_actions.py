"""Small build actions with explicit output roots and bounded cleanup."""
from __future__ import annotations
import argparse
import os
import sys
import shutil
from pathlib import Path

import automation_process
from build_paths import OUTPUT
from verification_paths import default_root, claim, remove


def clean(relative: str) -> None:
    # Build prefixes select immutable artifacts, never authorize deleting data.
    path = Path(relative)
    if not path.is_absolute():
        legacy = OUTPUT / relative
        if legacy.exists():
            print(f"Retaining legacy unowned verification evidence: {legacy}")
        return
    remove(path)


def main() -> int:
    global OUTPUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=OUTPUT)
    parser.add_argument("action", choices=("clean", "diag-runtime", "diag-portable", "diag-development", "run-portable", "run-python", "assert-portable-pure"))
    parser.add_argument("paths", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    OUTPUT = args.prefix.resolve()
    os.environ["CUTRANS_BUILD_PREFIX"] = str(OUTPUT)
    if args.action == "run-python":
        if not args.paths:
            parser.error("run-python needs a script")
        return automation_process.call([sys.executable, *args.paths])
    if args.action == "run-portable":
        raise RuntimeError("build output is disposable staging: copy the portable package to a user-chosen directory, or launch the exact artifact with an explicit isolated data root")
    if args.action == "diag-development":
        data = claim(default_root("development-diagnostic")) / "data"
        return automation_process.call([str(OUTPUT / "bin/cutrans_diag.exe"), f"--verify-data-dir={data}"])
    if args.action == "clean":
        for relative in args.paths:
            clean(relative)
        return 0
    if args.action in ("diag-portable", "assert-portable-pure") and (OUTPUT / "portable/data").exists():
        raise RuntimeError("portable staging contains application data; refusing to delete it")
    if args.action == "assert-portable-pure":
        return 0
    if args.action == "diag-runtime":
        data = claim(default_root("runtime-diagnostic")) / "data"
        command = [str(OUTPUT / "bin/cutrans_bootstrap.exe"), "--diag", f"--data={data}"]
    else:
        data = claim(default_root("portable-diagnostic")) / "data"
        command = [str(OUTPUT / "portable/cutrans_diag.exe"), "--mode=portable", f"--verify-data-dir={data}"]
    return automation_process.call(command)


if __name__ == "__main__":
    raise SystemExit(main())
