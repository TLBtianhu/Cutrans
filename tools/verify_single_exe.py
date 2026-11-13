"""Verify the one-executable portable artifact and its embedded cache repair."""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from verification_paths import claim, default_root, check_root, retain
from environment_harness import require, run_app


def run_scenario(console: Path, data: Path, log: Path, mode: str = "portable") -> str:
    return run_app(console, data, log, mode=mode)


def main() -> None:
    root = claim(default_root("single-exe"))
    try:
        console = (ROOT / "zig-out/single/cutrans.exe").resolve()
        require(console.is_file(), "build portable-single first")
        directory = console.parent
        entries = sorted(path.name for path in directory.iterdir())
        require(entries == ["cutrans.exe"],
            f"single artifact directory is not one executable: {entries}")

        cache_temp = check_root(root / "temp")
        cache_temp.mkdir()
        previous = {name: os.environ.get(name) for name in ("TEMP", "TMP")}
        try:
            os.environ["TEMP"] = str(cache_temp)
            os.environ["TMP"] = str(cache_temp)
            data = check_root(root / "data")
            text = run_scenario(console, data, check_root(root / "role.log"))
            require("CUTRANS_NANOUI_DESKTOP_OK" in text and "CUTRANS_ENVIRONMENT_STOPPED" in text,
                "single executable did not complete the headless NanoUI scenario")

            manifests = list(cache_temp.glob("**/desktop/payload.json"))
            require(len(manifests) == 1, "single executable did not materialize exactly one desktop cache")
            expected = manifests[0].read_bytes()
            manifests[0].write_bytes(b"{}")
            data2 = check_root(root / "data-repaired")
            text = run_scenario(console, data2, check_root(root / "repaired-role.log"))
            require("CUTRANS_NANOUI_DESKTOP_OK" in text and "CUTRANS_ENVIRONMENT_STOPPED" in text,
                "single executable did not recover after a corrupted cache")
            require(manifests[0].read_bytes() == expected,
                "single executable did not rewrite the corrupted cache manifest")
        finally:
            for name, value in previous.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value

        require(sorted(path.name for path in directory.iterdir()) == ["cutrans.exe"],
            "single executable run created external payload/context files")

        # An installed shape must select the embedded installed context; no
        # external cutrans-context.json is supplied.
        installed_root = check_root(root / "installed")
        installed_root.mkdir()
        installed_app = check_root(installed_root / "app")
        installed_app.mkdir()
        shutil.copyfile(console, installed_app / "cutrans.exe")
        installed_console = installed_app / "cutrans.exe"
        installed_data = check_root(root / "installed-data")
        text = run_scenario(installed_console, installed_data, check_root(root / "installed-role.log"), mode="installed")
        require("CUTRANS_NANOUI_DESKTOP_OK" in text and "CUTRANS_ENVIRONMENT_STOPPED" in text,
            "installed single executable did not use its embedded installed context")
        require(sorted(path.name for path in installed_app.iterdir()) == ["cutrans.exe"],
            "installed single executable created an external context file")

        print("CUTRANS_SINGLE_EXE_VERIFY_OK files=1 single_process=1 desktop=1 stop=1 cache_repaired=1 installed_context=1 external_payload=0 external_context=0")
    finally:
        retain(root)
        print(f"Single-exe evidence retained: {root}")


if __name__ == "__main__":
    main()
