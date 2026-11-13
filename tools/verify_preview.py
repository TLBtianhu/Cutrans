"""Verify VM preview frames inside two single-process desktop instances."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from verification_paths import check_root, claim, default_root, retain
from environment_harness import desktop_case, require

ROOT = Path(__file__).resolve().parents[1]
EPOCH = re.compile(r"epoch=([0-9a-f]+):([0-9a-f]+)")


def read_epoch(text: str) -> tuple[str, str]:
    match = EPOCH.search(text)
    require(match is not None, "preview marker did not expose a runtime epoch")
    return match.group(1), match.group(2)
def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("preview"))
    args = parser.parse_args()
    root = claim(args.root)
    console = (OUTPUT / "portable" / "cutrans.exe").resolve()
    require(console.is_file(), "portable cutrans.exe is missing; build portable first")
    evidence = {"format": "cutrans-preview-verification/1", "root": str(root), "checks": [], "passed": False}
    try:
        desktop_case(console, root, evidence)
        first_log = (root / "desktop.log").read_text(encoding="utf-8")
        second_log = (root / "desktop-again.log").read_text(encoding="utf-8")
        for log in (first_log, second_log):
            require("CUTRANS_PREVIEW_OK" in log, "the hidden desktop did not exercise VM preview frames")
            require("cache=1 short_buffer=1" in log,
                "preview verification did not cover cache reuse and short-buffer rejection")
            require("epoch=" in log and "revision=" in log,
                "preview verification did not expose the runtime epoch/revision")
        require(read_epoch(first_log) != read_epoch(second_log),
            "a new environment instance reused the previous preview epoch")
        evidence["checks"].append("single_process_preview_frames_cache_short_buffer_stale")
        evidence["checks"].append("each_instance_has_a_new_preview_epoch")
        evidence["passed"] = True
        print("CUTRANS_PREVIEW_VERIFY_OK single_process=1 frames=2 cache=1 short_buffer=1 stale=1 instance_epoch_changed=1")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        (root / "preview.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)


if __name__ == "__main__":
    main()
