"""Generate a VM Pack manifest from actual staged files and the capability registry."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from product import identity

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_FILES = [
    "cutrans-context.json",
    "config/startup.ccb",
    "assets/examples/minimal.cut",
    "assets/examples/pngtest.png",
    "cutrans_vm_host.exe",
    "cutrans_shell.exe",
    "payload/desktop/payload.json",
    "payload/nanoui-library/payload.json",
]


def capability_ids() -> list[str]:
    text = (ROOT / "runtime/capabilities.zig").read_text(encoding="utf-8").split("const adapter_ids", 1)[0]
    ids = re.findall(r'\{\s*\.id\s*=\s*"([^"]+)"', text)
    if len(ids) != 7 or len(set(ids)) != len(ids):
        raise RuntimeError(f"unexpected capability registry: {ids}")
    return ids


def version() -> str:
    return identity()["version"]


def host_api() -> int:
    return identity()["host_api"]


def file_record(root: Path, relative: str) -> dict[str, object]:
    path = root / relative
    data = path.read_bytes()
    return {
        "path": relative,
        "byteLength": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--abi", default="windows-x64")
    parser.add_argument("--context", type=Path, help="installer-only immutable context replacement")
    args = parser.parse_args()
    root = Path(args.root)
    manifest = {
        "format": "cutrans-vm-pack/1",
        "id": "core",
        "version": version(),
        "vm_schema": 1,
        "host_api": host_api(),
        "document_schema": 3,
        "required_capabilities": capability_ids(),
        "native_dependencies": [],
        "files": [file_record(root, relative) if relative != "cutrans-context.json" or args.context is None else {
            "path": relative, "byteLength": args.context.stat().st_size,
            "sha256": hashlib.sha256(args.context.read_bytes()).hexdigest(),
        } for relative in REQUIRED_FILES],
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output)
    print(f"VM Pack core {manifest['version']} files={len(manifest['files'])} capabilities={len(manifest['required_capabilities'])} abi={args.abi}")


if __name__ == "__main__":
    main()
