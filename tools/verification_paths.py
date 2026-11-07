"""Project-owned verification cases; build output locations never authorize deletion."""
from __future__ import annotations
import json
import os
import re
import shutil
import uuid
from pathlib import Path
from product import identity

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "scratch/verification"
MARKER = ".cutrans-verification.json"


def _no_links(path: Path) -> Path:
    lexical = Path(os.path.abspath(path))
    if not lexical.is_relative_to(ROOT):
        raise RuntimeError(f"verification path is outside the project: {path}")
    current = lexical
    # Validate the project itself and all parents too: a workspace reached
    # through a junction must not authorize deletion in the link destination.
    while True:
        if current.exists() or current.is_symlink():
            info = current.lstat()
            if current.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
                raise RuntimeError(f"verification path contains a link or junction: {current}")
        if current.parent == current:
            break
        current = current.parent
    resolved = lexical.resolve()
    if not resolved.is_relative_to(BASE) or resolved == BASE:
        raise RuntimeError(f"verification path is outside its dedicated root: {path}")
    return resolved


def default_root(case: str) -> Path:
    if not re.fullmatch(r"[a-z0-9-]+", case):
        raise ValueError("invalid verification case name")
    return BASE / f"{case}-{uuid.uuid4().hex[:12]}"


def check_root(path: Path) -> Path:
    """Validate the lexical parent chain before resolving any aliases."""
    return _no_links(path)


def ensure_owned_data(path: Path) -> Path:
    """Only an already claimed case can authorize creating a data subdirectory."""
    path = _no_links(path)
    _owner(path)
    path.mkdir(parents=True, exist_ok=True)
    return path


def claim(path: Path) -> Path:
    path = _no_links(path)
    if path.exists():
        raise RuntimeError(f"verification case must be new; existing evidence retained: {path}")
    path.mkdir(parents=True)
    (path / MARKER).write_text(json.dumps({"format": "cutrans-verification/1", "product": identity()["id"],
                                         "purpose": "verification", "root": str(path)}, indent=2) + "\n", encoding="utf-8")
    return path


def _owner(path: Path) -> Path:
    target = _no_links(path)
    current = target if target.is_dir() else target.parent
    while current.is_relative_to(BASE) and current != BASE:
        marker = current / MARKER
        _no_links(marker)
        if marker.is_file():
            data = json.loads(marker.read_text(encoding="utf-8"))
            if data != {"format": "cutrans-verification/1", "product": identity()["id"], "purpose": "verification", "root": str(current)}:
                raise RuntimeError(f"verification ownership marker mismatch: {current}")
            return current
        current = current.parent
    raise RuntimeError(f"unowned verification data is retained: {target}")


def retain(path: Path, **_ignored) -> None:
    if not path.exists():
        return
    owner = _owner(path)
    _no_links(owner / "evidence-retained.txt").write_text("Verification files retained for review; explicit cleanup requires the ownership marker.\n", encoding="utf-8")


def remove(path: Path, ignore_errors: bool = False) -> None:
    if not path.exists() and not path.is_symlink():
        return
    target = _no_links(path)
    _owner(target)
    # Reject nested reparse points before any recursive deletion. Never use an
    # ignore-errors fallback that could hide a path ownership failure.
    for directory, dirs, files in os.walk(target, followlinks=False):
        for name in dirs + files:
            _no_links(Path(directory) / name)
    shutil.rmtree(target)
