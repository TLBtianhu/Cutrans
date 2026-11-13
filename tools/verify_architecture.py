"""Reject direct cross-layer imports that bypass the Shell/VM projection boundary."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# A layer may import lower/shared layers, but never reach across this table.
FORBIDDEN = {
    "vne": ("runtime", "bootstrap", "apps", "shell", "consoles"),
    "runtime": ("bootstrap", "apps", "nanoui", "consoles"),
    "apps": ("runtime", "bootstrap"),
    "shell": ("runtime", "bootstrap"),
    "bootstrap": ("apps", "nanoui"),
}
FILE_FORBIDDEN = {
    "consoles/gui/vm_client.zig": ("runtime", "bootstrap"),
    "consoles/cli/nanoui.zig": ("runtime", "bootstrap"),
}
IMPORT = re.compile(r'@import\("([^"]+)"\)')


def zig_files(layer: str):
    root = ROOT / layer
    if not root.is_dir():
        return
    for path in sorted(root.rglob("*.zig")):
        yield path


def main() -> None:
    failures: list[str] = []
    for layer, forbidden in FORBIDDEN.items():
        for path in zig_files(layer):
            check(path, layer, forbidden, failures)
    for relative, forbidden in FILE_FORBIDDEN.items():
        path = ROOT / relative
        if path.is_file():
            check(path, relative, forbidden, failures)
    if failures:
        raise RuntimeError("architecture boundary violations:\n" + "\n".join(failures))
    print("CUTRANS_ARCHITECTURE_OK layers=6 shell_runtime_leak=0")


def check(path: Path, layer: str, forbidden: tuple[str, ...], failures: list[str]) -> None:
    text = path.read_text(encoding="utf-8")
    for line_number, line in enumerate(text.splitlines(), 1):
        for name in IMPORT.findall(line):
            if name in forbidden:
                rel = path.relative_to(ROOT)
                failures.append(f"{rel}:{line_number}: {layer} imports {name}")


if __name__ == "__main__":
    main()
