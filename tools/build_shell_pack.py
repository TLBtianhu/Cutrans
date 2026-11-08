"""Generate a Shell Pack manifest consumed by the VM Runtime."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True

from build_vm_pack import capability_ids, file_record, version, host_api


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--abi", required=True)
    parser.add_argument("--entry", required=True)
    parser.add_argument("--id", default="desktop-shell")
    parser.add_argument("--file", dest="files", action="append")
    parser.add_argument("--all-files", action="store_true", help="Include every declared staged payload")
    args = parser.parse_args()
    root = Path(args.root)
    files = (sorted(path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file()) if args.all_files else args.files) or [
        args.entry,
        "config/startup.ccb",
        "assets/commands/00-example.ccmd",
        "assets/examples/minimal.cut",
        "assets/examples/replay.cvr",
        "assets/examples/input.cvr",
        "assets/examples/pngtest.png",
        "assets/examples/SOURCES.md",
        "assets/examples/libpng-LICENSE.txt",
        "licenses/Cutrans.txt",
        "licenses/stb.txt",
        "licenses/nanoui.txt",
        "licenses/nanoui-THIRD_PARTY_NOTICES.md",
        "licenses/GPUI-Apache-2.0.txt",
        "licenses/GPUI-Kit-Apache-2.0.txt",
        "licenses/gpui-motion-MIT.txt",
        "licenses/mygo-MIT.txt",
        "licenses/Windows-Terminal-MIT.txt",
    ]
    manifest = {
        "format": "cutrans-shell-pack/1",
        "id": args.id,
        "version": version(),
        "abi": args.abi,
        "entry": args.entry,
        "vm_schema": 1,
        "host_api": host_api(),
        "document_schema": 3,
        "required_capabilities": capability_ids(),
        "files": [file_record(root, relative) for relative in files],
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output)
    print(f"Shell Pack {manifest['id']} {manifest['version']} files={len(files)} capabilities={len(manifest['required_capabilities'])} abi={args.abi}")


if __name__ == "__main__":
    main()
