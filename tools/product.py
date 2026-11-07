"""Read the narrow product constants shared by native code and build projections."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def identity():
    text = (ROOT / "vne/product.zig").read_text(encoding="utf-8")
    values = {key: json.loads(value) for key, value in re.findall(
        r'pub const (\w+) = ("(?:[^"\\]|\\.)*"|true|false);', text)}
    declared = re.search(r'\.version\s*=\s*"([^"]+)"', (ROOT / "build.zig.zon").read_text(encoding="utf-8"))
    if not declared or declared.group(1) != values["version"]:
        raise RuntimeError("product and package version declarations disagree")
    abi = re.search(r'pub const version: u32 = (\d+);', (ROOT / "vne/abi.zig").read_text(encoding="utf-8"))
    if not abi:
        raise RuntimeError("missing native ABI declaration")
    values["host_api"] = int(abi.group(1))
    if any(values[key] for key in ("updates_enabled", "accounts_enabled", "telemetry_enabled")):
        raise RuntimeError("unconfigured update/account/telemetry service must stay disabled")
    return values
