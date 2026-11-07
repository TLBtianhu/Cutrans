"""Check the exact effective source trees recorded in dependencies.lock.json."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "dependencies.lock.json"
SKIP_DIRS = {".git", ".zig-cache", "zig-out", "zig-pkg", "__pycache__"}
NATIVE_SUFFIXES = {".exe", ".dll", ".lib", ".pdb"}


def source_tree(path: Path) -> tuple[str, int]:
    """Hash sorted portable paths plus file bytes, excluding restored native binaries."""
    digest = hashlib.sha256()
    count = 0
    for file in sorted(path.rglob("*"), key=lambda p: p.relative_to(path).as_posix()):
        relative = file.relative_to(path)
        if any(part in SKIP_DIRS for part in relative.parts):
            continue
        if file.is_symlink():
            raise ValueError(f"vendored source contains a symlink: {relative}")
        if not file.is_file() or file.suffix.lower() in NATIVE_SUFFIXES:
            continue
        name = relative.as_posix().encode("utf-8")
        # Git checkouts may use CRLF. Normalize text only; binary assets stay exact.
        data = file.read_bytes()
        if b"\0" not in data:
            try:
                data.decode("utf-8")
            except UnicodeDecodeError:
                pass
            else:
                data = data.replace(b"\r\n", b"\n")
        digest.update(len(name).to_bytes(4, "little"))
        digest.update(name)
        digest.update(len(data).to_bytes(8, "little"))
        digest.update(data)
        count += 1
    return digest.hexdigest(), count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", action="store_true", help="explicitly record reviewed source changes")
    args = parser.parse_args()
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    if lock.get("format") != "cutrans-dependencies/1":
        raise SystemExit("unsupported dependency lock format")
    failures = []
    bootstrap = (ROOT / "tools/bootstrap.py").read_text(encoding="utf-8")
    constants = {}
    for statement in ast.parse(bootstrap).body:
        if isinstance(statement, ast.Assign) and isinstance(statement.value, ast.Constant):
            for target in statement.targets:
                if isinstance(target, ast.Name):
                    constants[target.id] = statement.value.value
    toolchain = lock["toolchain"]
    if toolchain["url"] != constants.get("ZIG_URL") or toolchain["archive_sha256"] != constants.get("ZIG_ARCHIVE_SHA256"):
        failures.append("toolchain bootstrap declaration")
    for item in lock.get("fetched_sources", []):
        if item["name"] != "http_zig":
            raise SystemExit(f"unsupported fetched source audit: {item['name']}")
        declaration = (ROOT / "third_party/nanoui/build.zig.zon").read_text(encoding="utf-8")
        expected = (item["revision"], item["archive_sha256"], item["zig_package_hash"])
        actual = tuple(constants.get(name) for name in ("HTTP_COMMIT", "HTTP_ARCHIVE_SHA256", "HTTP_PACKAGE_HASH"))
        if actual != expected or item["revision"] not in declaration or item["zig_package_hash"] not in declaration:
            failures.append("http-zig bootstrap/NanoUI declaration")
    for item in lock["sources"]:
        path = (ROOT / item["path"]).resolve()
        if not path.is_relative_to(ROOT) or not path.is_dir():
            raise SystemExit(f"invalid dependency directory: {item['name']}")
        actual, count = source_tree(path)
        if args.record:
            item["effective_sha256"] = actual
            item["source_files"] = count
        elif actual != item.get("effective_sha256") or count != item.get("source_files"):
            failures.append(item["name"])
        print(f"{item['name']}: files={count} sha256={actual}")
    if failures:
        raise SystemExit("dependency source or declaration drift: " + ", ".join(failures))
    if args.record:
        LOCK.write_text(json.dumps(lock, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("CUTRANS_DEPENDENCIES_RECORDED (review and commit the changed lock)")
    else:
        print(f"CUTRANS_DEPENDENCIES_OK sources={len(lock['sources'])}")


if __name__ == "__main__":
    main()
