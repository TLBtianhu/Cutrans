"""Verify canonical .cut tails and the save recovery marker through the real console."""

from __future__ import annotations

import argparse
import base64
import os
import sys
from pathlib import Path

sys.dont_write_bytecode = True

import automation_process
from build_paths import OUTPUT
from verification_context import command_args
from verification_paths import check_root, claim, default_root, retain
from verify_host import invoke

COMPLETE = (
    "version=3\nresolution=8x4\nfps=30\nnodes:\n"
    "c0=testsrc{}\n"
    "c1=gain{ in:c0,value:0.5 }\n"
    "output=c1\n"
)
TRUNCATED = COMPLETE[: COMPLETE.rindex("output=")]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def headless(console: Path, document: Path, data: Path):
    command = [str(console), "--mode=portable", "--purpose=verification",
               f"--data={data}", "--headless", f"--open={document}"]
    result = automation_process.run(command_args(command), capture_output=True, text=True, timeout=90)
    print(result.stdout, end="")
    print(result.stderr, end="")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("write-order"))
    args = parser.parse_args()
    require(os.name == "nt", "write-order verification requires Windows")
    root = claim(args.root)
    console = (OUTPUT / "portable" / "cutrans.exe").resolve()
    require(console.is_file(), "portable cutrans.exe is missing; build portable first")
    checks: list[str] = []
    try:
        complete = check_root(root / "complete.cut")
        complete.write_text(COMPLETE, encoding="utf-8")
        accepted = headless(console, complete, root / "data-complete")
        require(accepted.returncode == 0,
                f"a canonical v3 document was rejected: {accepted.stdout}{accepted.stderr}")
        checks.append("canonical_v3_with_explicit_output_opens")

        truncated = check_root(root / "truncated.cut")
        truncated.write_text(TRUNCATED, encoding="utf-8")
        refused = headless(console, truncated, root / "data-truncated")
        require(refused.returncode != 0, "a line-aligned truncated v3 document was accepted")
        checks.append("line_aligned_truncation_without_output_is_refused")

        data = root / "data"
        invoke(console, "start", data, "portable")
        invoke(console, "stop", data, "portable")
        journal = (data / "documents" / "history.txt").read_text(encoding="utf-8")
        require("dirty=0" in journal, "a completed save did not confirm a clean recovery marker")
        artifact = (data / "documents" / "session.cut").read_bytes()
        encoded = next((line[len("document="):] for line in journal.splitlines()
                        if line.startswith("document=")), None)
        require(encoded is not None, "the recovery journal has no document body")
        # The journal stores standard base64 without padding.
        decoded = base64.b64decode(encoded + "=" * (-len(encoded) % 4))
        require(decoded == artifact,
                "the recovery journal and the saved artifact disagree")
        checks.append("save_confirms_clean_marker_and_matches_artifact")

        staging = sorted(path.name for path in (data / "documents").iterdir())
        require(staging == ["history.txt", "session.cut"],
                f"unexpected document staging files: {staging}")
        checks.append("atomic_replace_leaves_no_staging_siblings")
        print(f"CUTRANS_WRITE_ORDER_OK checks={len(checks)} " + " ".join(checks))
    finally:
        retain(root)


if __name__ == "__main__":
    main()
