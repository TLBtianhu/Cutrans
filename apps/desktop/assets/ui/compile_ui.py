#!/usr/bin/env python3
"""Compile a desktop JSON declaration to an explicit CUI v2 output path.

Only the encoder lives here. View ids, navigation metadata and node trees all
come from the sibling JSON document. No Python evaluation is involved.
"""

from pathlib import Path
import argparse
import json
import struct

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=HERE / "desktop.json")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
SOURCE, OUT = args.source, args.output
NONE = 0xFFFFFFFF

TEXT, BUTTON, LIST_ITEM, INPUT, CARD, VSTACK, HSTACK, SPACE = range(1, 9)
NONE_ACTION, CMD = range(2)
KINDS = {"primary": 0, "secondary": 1, "launch": 2, "ghost": 3, "destructive": 4}
DIM, CENTER, SELECTED, HAS_W, HAS_H = 1, 2, 4, 8, 16

strings = bytearray()
string_offsets = {}
records = bytearray()
view_table = bytearray()
node_count = 0


def intern(value):
    if value is None:
        return NONE
    encoded = value.encode("utf-8")
    if encoded not in string_offsets:
        string_offsets[encoded] = len(strings)
        strings.extend(encoded + b"\0")
    return string_offsets[encoded]


def emit(op, *, flags=0, action=NONE_ACTION, kind=0, a=0.0, b=0.0, c=0.0,
         s0=None, s1=None, s2=None, s3=None, arg=NONE, children=()):
    global node_count
    node_count += 1
    records.extend(struct.pack(
        "<BBBBfffIIIIII", op, flags, action, kind, a, b, c,
        intern(s0), intern(s1), intern(s2), intern(s3), arg, len(children),
    ))
    for child in children:
        emit_node(child)


def action_fields(node):
    action = node.get("action")
    if action is None:
        return NONE_ACTION, NONE
    return CMD, intern(action)


def emit_node(node):
    kind = node["type"]
    children = node.get("children", ())
    if kind == "text":
        flags = (DIM if node.get("dim", False) else 0) | (CENTER if node.get("center", False) else 0)
        emit(TEXT, flags=flags, a=node.get("size", 0.0), s0=node["text"])
    elif kind == "button":
        action = node.get("action")
        action_kind, action_arg = (NONE_ACTION, NONE) if action is None else (CMD, intern(action))
        emit(BUTTON, action=action_kind, kind=KINDS[node.get("kind", "secondary")], a=node.get("h", 34.0),
             s0=node["id"], s1=node["label"], s2=node.get("sub"), arg=action_arg)
    elif kind == "list":
        action, arg = action_fields(node)
        emit(LIST_ITEM, flags=SELECTED if node.get("selected", False) else 0,
             action=action, arg=arg,
             s0=node["id"], s1=node["icon"], s2=node["title"], s3=node.get("info", ""))
    elif kind == "input":
        emit(INPUT, s0=node["id"], s1=node["hint"], s2=node["buffer"])
    elif kind == "card":
        flags = (HAS_W if "w" in node else 0) | (HAS_H if "h" in node else 0)
        emit(CARD, flags=flags, a=node.get("pad", 12.0), b=node.get("w", 0.0),
             c=node.get("h", 0.0), s0=node["id"], children=children)
    elif kind in ("vstack", "hstack"):
        emit(VSTACK if kind == "vstack" else HSTACK,
             a=node.get("gap", 8.0), b=node.get("margin", 0.0), children=children)
    elif kind == "space":
        emit(SPACE, a=node["h"])
    else:
        raise ValueError(f"unknown node type: {kind}")


document = json.loads(SOURCE.read_text(encoding="utf-8"))
if document.get("format") != "cutrans-view-v2":
    raise ValueError("desktop.json: expected format=cutrans-view-v2")
views = document["views"]
if len(views) > 1024:
    raise ValueError(f"too many views: {len(views)}")

for view in views:
    view_table.extend(struct.pack("<III", intern(view["id"]), intern(view["label"]), intern(view["icon"])))
for view in views:
    emit_node(view["side"])
    emit_node(view["content"])

strings_offset = 24 + len(view_table) + len(records)
header = struct.pack("<4sHHIIII", b"CUI1", 2, 24, len(views), 40, strings_offset, len(strings))
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_bytes(header + view_table + records + strings)
print(f"wrote {OUT} | {OUT.stat().st_size} bytes | {len(views)} views / {node_count} nodes | "
      f"{len(string_offsets)} strings / {len(strings)} bytes")
