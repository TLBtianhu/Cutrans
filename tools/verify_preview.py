"""Verify preview frames through a real Host and hidden Desktop Shell."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from verification_paths import check_root, claim, default_root, retain
from verify_host import invoke
from verify_same_file import desktop_case, require, run_role

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
        role_log = (root / "desktop-role.log").read_text(encoding="utf-8")
        require("CUTRANS_PREVIEW_OK" in role_log,
            "the hidden desktop did not exercise VM preview frames")
        require("cache=1 short_buffer=1" in role_log,
            "preview verification did not cover cache reuse and short-buffer rejection")
        require("epoch=" in role_log and "revision=" in role_log,
            "preview verification did not expose the runtime epoch/revision")
        first_epoch = read_epoch(role_log)

        data = root / "desktop data"
        document = root / "desktop document.cut"
        _, restarted = invoke(console, "start", data, "portable")
        require(restarted["boot"] >= 1, "the Host did not restart for the preview epoch check")
        try:
            restart_log = run_role(console, data, "shell", console.parent / "payload/desktop",
                check_root(root / "desktop-role-restart.log"), document)
        finally:
            try:
                invoke(console, "stop", data, "portable")
            except Exception as error:
                evidence["restart_cleanup_error"] = repr(error)
        require("CUTRANS_PREVIEW_OK" in restart_log,
            "preview did not survive a Host restart")
        require("CUTRANS_PREVIEW_EPOCH_RESET" in restart_log,
            "the restarted Host did not reject the pre-restart preview epoch")
        second_epoch = read_epoch(restart_log)
        require(first_epoch != second_epoch,
            "a restarted Host reused the previous preview epoch")
        evidence["checks"].append("real_host_hidden_shell_preview_frames_cache_short_buffer_stale")
        evidence["checks"].append("host_restart_changes_preview_epoch")
        evidence["passed"] = True
        print("CUTRANS_PREVIEW_VERIFY_OK host=1 hidden_shell=1 frames=2 cache=1 short_buffer=1 stale=1 restart_epoch_changed=1")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        (root / "preview.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)


if __name__ == "__main__":
    main()
