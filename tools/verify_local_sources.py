"""Verify one-level local browsing and explicit registration on real artifacts.

Only claimed synthetic directories are changed. Browsing creates no ResourceId,
grant, retained bytes or Station lease. GUI coverage uses the hidden UI Tester.
"""
from __future__ import annotations

import argparse
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import struct
import sys

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from product import identity
from verification_paths import check_root, claim, default_root, retain
from environment_harness import run_app
from verify_input import ByteSlice, hashes
from verify_jobs import OK, SMALL, require, tiny_png
from verify_resource_operations import Native, configure, request
from verify_resource_versions import COLOR_A

VERSION = 4
BROWSE, LOCAL_READ = 31, 32
BROWSE_HEADER, READ_HEADER = 24, 16


class LocalClient(Native):
    def browse(self, path, cursor=0, limit=128, expected=SMALL):
        read = c.cast(self.resources.source_browse, BrowseFn)
        path_value, storage = string_bytes(str(path))
        required = c.c_size_t(999)
        status = read(self.handle, path_value, cursor, limit, None, 0, c.byref(required))
        require(status == expected, f"local browse query={status}, expected={expected}")
        if status != SMALL:
            return None
        require(0 < required.value <= 1024 * 1024, "unbounded local browse result")
        output = c.create_string_buffer(required.value)
        status = read(self.handle, path_value, cursor, limit, output, len(output), c.byref(required))
        require(status == OK and required.value == len(output), f"local browse read failed: {status}")
        result = json.loads(output.raw)
        require(result["format"] == "cutrans-local-directory/1" and Path(result["path"]) == Path(path)
            and result["cursor"] == cursor and len(result["entries"]) <= 128,
            "local browse returned another path or page")
        return result

    def read(self, path, expected=SMALL):
        read = c.cast(self.resources.source_read, ReadFn)
        path_value, storage = string_bytes(str(path))
        required = c.c_size_t(999)
        status = read(self.handle, path_value, None, 0, c.byref(required))
        require(status == expected, f"local read query={status}, expected={expected}")
        if status != SMALL:
            return None
        require(required.value <= 16 * 1024 * 1024, "unbounded local file read")
        output = c.create_string_buffer(max(1, required.value))
        status = read(self.handle, path_value, output, len(output), c.byref(required))
        require(status == OK and required.value <= len(output), f"local file read failed: {status}")
        return output.raw[:required.value]


BrowseFn = c.CFUNCTYPE(c.c_int32, c.c_void_p, ByteSlice, c.c_uint64, c.c_uint32,
    c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t))
ReadFn = c.CFUNCTYPE(c.c_int32, c.c_void_p, ByteSlice, c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t))


def string_bytes(value):
    encoded = value.encode("utf-8")
    storage = c.create_string_buffer(encoded)
    return ByteSlice(c.cast(storage, c.c_void_p), len(encoded)), storage


def make_fixture(root):
    source = check_root(root / "local source")
    source.mkdir(parents=True)
    (source / "nested").mkdir()
    (source / "nested/child.txt").write_text("nested child", encoding="utf-8")
    (source / "a.txt").write_text("local text", encoding="utf-8")
    (source / "b.png").write_bytes(tiny_png(COLOR_A))
    (source / "unknown.bin").write_bytes(b"\x00local-unknown\xff")
    (source / "empty.bin").write_bytes(b"")
    for index in range(130):
        (source / f"f{index:03d}.txt").write_text(f"synthetic page {index}", encoding="utf-8")
    return source


def dll_case(library, runtime_dir, root, evidence):
    case = check_root(root / "dll")
    case.mkdir()
    source = make_fixture(case)
    data = case / "data"
    runtime = LocalClient(library, runtime_dir, data, evidence)
    try:
        first = runtime.browse(source, 0, 1)
        require(first["entries"][0]["name"] == "nested" and first["next_cursor"] == 1,
            "directory-first one-level ordering was not preserved")
        second = runtime.browse(source, 1, 1)
        require(second["entries"][0]["name"] == "a.txt", "second local page skipped a member")
        require(runtime.read(source / "a.txt") == b"local text"
            and runtime.read(source / "b.png") == tiny_png(COLOR_A)
            and runtime.read(source / "unknown.bin") == b"\x00local-unknown\xff"
            and runtime.read(source / "empty.bin") == b"", "local reads changed or substituted bytes")
        require(not (data / "library/catalog.json").exists()
            and not (data / "session/external-sources.json").exists()
            and not runtime.view()["body"]["resources"], "browsing or preview created persistent resources or grants")
        runtime.browse(data, expected=4)
        require(runtime.view()["body"]["resources"] == [], "managed-root refusal published a resource")
        proof = runtime.probe(source / "a.txt", 3, 0)
        registered = runtime.apply(request(proof, source / "a.txt", client=(0xD401, 1)))
        require(registered.resource_id == 1 and len(runtime.view()["body"]["resources"]) == 1,
            "explicit local registration did not publish exactly one resource")
        require((source / "a.txt").read_bytes() == b"local text", "registration changed the original")
        evidence["checks"].append("dll_one_level_pages_exact_bytes_no_registration_or_grant_then_explicit_register")
    finally:
        runtime.close()
    runtime = LocalClient(library, runtime_dir, data, evidence)
    try:
        require(len(runtime.view()["body"]["resources"]) == 1
            and runtime.browse(source, 0, 1)["entries"][0]["name"] == "nested",
            "cold restore confused registered resources with ordinary directory observations")
        evidence["checks"].append("cold_restore_preserves_explicit_registration_without_expanding_directory")
    finally:
        runtime.close()


def gui_case(console, root, evidence):
    """The local-files page runs inside the single-process environment."""
    source = make_fixture(check_root(root / "gui source"))
    data = check_root(root / "gui data")
    output = run_app(console, data, check_root(root / "gui.log"), document=source, demo="--files-demo")
    require("CUTRANS_LOCAL_FILES_OK" in output and "CUTRANS_SHELL_PRECHECK_OK id=desktop-shell" in output
        and "CUTRANS_ENVIRONMENT_SESSION_OK" in output and "CUTRANS_ENVIRONMENT_STOPPED" in output,
        "local-files UI did not establish the environment and complete browse, page, text, directory, register and insert")
    evidence["checks"].append("native_ui_browse_text_nested_page_refresh_explicit_register_and_insert")
    evidence["gui_stopped"] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("local-sources"))
    args = parser.parse_args()
    require(os.name == "nt" and identity()["host_api"] >= 10, "local-source verification requires Windows and ABI10+")
    root = claim(args.root)
    portable = (OUTPUT / "portable").resolve()
    before = hashes(portable)
    evidence = {"format": "cutrans-local-sources-verification/1", "root": str(root),
        "artifact_hashes": before, "checks": [], "passed": False}
    try:
        library = c.WinDLL(str(portable / "runtime/cutrans_vm_runtime.dll"))
        configure(library)
        dll_case(library, portable / "runtime", root, evidence)
        gui_case(portable / "cutrans.exe", root, evidence)
        require(hashes(portable) == before, "local-source verification modified its tested artifact")
        evidence["passed"] = True
        print("CUTRANS_LOCAL_SOURCES_VERIFY_OK dll=1 single_process_ui=1 no_implicit_registration=1")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        (root / "local-sources.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)
        print(f"Local-source evidence retained: {root}")


if __name__ == "__main__":
    main()
