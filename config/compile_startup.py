#!/usr/bin/env python3
"""Compile the human-editable startup.ccmd into binary startup.ccb (CCB1)."""

import argparse
from pathlib import Path
import struct

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=HERE / "startup.ccmd")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
SOURCE, OUT = args.source, args.output
OPCODES = {
    "console.cli.start": 1,
    "font.main": 3,
    "locale.default": 4,
    "cli.load": 5,
    "app.open": 6,
    "session.shell": 7,
    "taskbar.pin": 8,
}

records = bytearray()
count = 0
for raw in SOURCE.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    name, _, arg = line.partition(" ")
    arg = arg.strip()
    if len(arg) >= 2 and arg[0] == '"' and arg[-1] == '"':
        arg = arg[1:-1]
    if name not in OPCODES:
        raise ValueError(f"unknown startup command: {name}")
    payload = arg.encode("utf-8")
    records.extend(struct.pack("<HHI", OPCODES[name], 0, len(payload)))
    records.extend(payload)
    count += 1

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_bytes(struct.pack("<4sHHI", b"CCB1", 1, 0, count) + records)
print(f"wrote {OUT} | {OUT.stat().st_size} bytes | {count} binary commands")
