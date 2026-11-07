"""Artifact location only. Verification data lives in project-owned scratch cases."""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_override = os.environ.get("CUTRANS_BUILD_PREFIX")
if _override and not Path(_override).is_absolute():
    raise RuntimeError("CUTRANS_BUILD_PREFIX must be absolute; cwd-relative artifact fallback is forbidden")
OUTPUT = Path(_override or ROOT / "zig-out").resolve()
