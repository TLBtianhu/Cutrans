"""Verify Station assets, adopted library versions and Content Snapshots through a distributed Runtime."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import shutil
import sys
from pathlib import Path

sys.dont_write_bytecode = True

from verify_input import ABI_VERSION, ByteSlice, Config, hashes, run, string_slice

ROOT = Path(__file__).resolve().parents[1]
from build_paths import OUTPUT
from verification_paths import default_root, claim, retain, remove, check_root
from verification_context import mark_data


class LibraryEntry(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("id", ctypes.c_uint64),
        ("parent_id", ctypes.c_uint64),
        ("node_kind", ctypes.c_uint32),
        ("kind", ctypes.c_uint32),
        ("provenance", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("content_hash", ctypes.c_ubyte * 32),
    ]


class LibraryListReport(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("revision", ctypes.c_uint64),
        ("count", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("entries", LibraryEntry * 64),
    ]


class AssetListEntry(ctypes.Structure):
    _fields_ = [
        ("handle", ctypes.c_uint64),
        ("byte_length", ctypes.c_uint64),
        ("leases", ctypes.c_uint32),
        ("source_kind", ctypes.c_uint32),
        ("library_kind", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("library_id", ctypes.c_uint64),
        ("content_hash", ctypes.c_ubyte * 32),
        ("source_status", ctypes.c_uint32),
        ("reserved2", ctypes.c_uint32),
    ]


class AssetListReport(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("revision", ctypes.c_uint64),
        ("count", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("entries", AssetListEntry * 16),
    ]


class AssetInfo(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("handle", ctypes.c_uint64),
        ("byte_length", ctypes.c_uint64),
        ("content_hash", ctypes.c_ubyte * 32),
        ("width", ctypes.c_uint32),
        ("height", ctypes.c_uint32),
        ("media_kind", ctypes.c_uint32),
        ("coverage", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
    ]


def read_buffer(library: ctypes.WinDLL, handle: ctypes.c_void_p, function_name: str, asset_id: int = 0) -> bytes:
    function = getattr(library, function_name)
    required = ctypes.c_size_t()
    args = (handle, asset_id, None, 0, ctypes.byref(required)) if asset_id else (handle, None, 0, ctypes.byref(required))
    if function(*args) != 15:
        raise RuntimeError(f"{function_name} did not return the required size")
    output = ctypes.create_string_buffer(required.value)
    args = (handle, asset_id, output, len(output), ctypes.byref(required)) if asset_id else (handle, output, len(output), ctypes.byref(required))
    if function(*args) != 0:
        raise RuntimeError(f"{function_name} did not return the content")
    return output.raw[: required.value]


def library_projection(library: ctypes.WinDLL, handle: ctypes.c_void_p, expected_count: int) -> tuple[LibraryListReport, list[str]]:
    report = LibraryListReport()
    if library.cutrans_vm_library_list(handle, ctypes.byref(report)) != 0:
        raise RuntimeError("could not read the library directory")
    if report.struct_size != ctypes.sizeof(LibraryListReport) or report.abi_version != ABI_VERSION or report.reserved != 0 or report.count != expected_count:
        raise RuntimeError("library directory has invalid metadata")
    labels = []
    entries = {}
    for entry in report.entries[: report.count]:
        if entry.struct_size != ctypes.sizeof(LibraryEntry) or entry.abi_version != ABI_VERSION or entry.id == 0 or entry.reserved != 0:
            raise RuntimeError("library directory entry has invalid identity")
        if entry.id in entries or entry.parent_id == entry.id or entry.node_kind not in (1, 2):
            raise RuntimeError("library directory contains duplicate or invalid nodes")
        if entry.node_kind == 1:
            if entry.kind != 0 or entry.provenance != 0 or any(entry.content_hash):
                raise RuntimeError("folder contains resource-only metadata")
        elif entry.kind not in (1, 2) or entry.provenance not in (0, 1, 2) or (entry.kind == 1) != (entry.provenance == 0):
            raise RuntimeError("library directory entry has inconsistent ownership or provenance")
        label = read_buffer(library, handle, "cutrans_vm_library_label", entry.id).decode("utf-8")
        if not label or len(label.encode("utf-8")) > 128:
            raise RuntimeError("library directory returned an invalid label")
        labels.append(label)
        entries[entry.id] = entry
    for entry in entries.values():
        if entry.parent_id and (entry.parent_id not in entries or entries[entry.parent_id].node_kind != 1):
            raise RuntimeError("library directory contains an orphan or a non-folder parent")
        if entry.node_kind != 1:
            continue
        seen = {entry.id}
        parent_id = entry.parent_id
        while parent_id:
            if parent_id in seen:
                raise RuntimeError("library directory contains a folder cycle")
            seen.add(parent_id)
            parent_id = entries[parent_id].parent_id
    return report, labels


def asset_projection(library: ctypes.WinDLL, handle: ctypes.c_void_p, asset_id: int) -> tuple[AssetInfo, bytes, str]:
    info = AssetInfo()
    if library.cutrans_vm_asset_preview(handle, asset_id, ctypes.byref(info)) != 0:
        raise RuntimeError("asset projection was not readable")
    if info.struct_size != ctypes.sizeof(AssetInfo) or info.abi_version != ABI_VERSION or info.handle != asset_id or info.media_kind != 1 or info.coverage != 1:
        raise RuntimeError("asset projection has invalid identity or coverage")
    content = read_buffer(library, handle, "cutrans_vm_asset_read", asset_id)
    if len(content) != info.byte_length or hashlib.sha256(content).digest() != bytes(info.content_hash):
        raise RuntimeError("asset projection content does not match its identity")
    source = read_buffer(library, handle, "cutrans_vm_asset_source", asset_id).decode("utf-8")
    return info, content, source


def _verify_external_reference(library: ctypes.WinDLL, runtime_dir: Path, root: Path, mode: str) -> None:
    data_dir = mark_data(root / "external reference data", mode, runtime_dir)
    source = root / "reference-source.png"
    shutil.copyfile(runtime_dir / "assets/examples/pngtest.png", source)
    resource, resource_storage = string_slice(str(runtime_dir))
    data, data_storage = string_slice(str(data_dir))
    config = Config(ctypes.sizeof(Config), ABI_VERSION, 1 if mode == "portable" else 2, 0, resource, data)

    def create() -> ctypes.c_void_p:
        handle = ctypes.c_void_p()
        if library.cutrans_vm_create(ctypes.byref(config), ctypes.byref(handle)) != 0 or not handle.value:
            raise RuntimeError("could not create the external-reference Runtime")
        return handle

    def command(handle: ctypes.c_void_p, name: str, argument: str | None = None, expected: int = 0) -> None:
        name_slice, name_storage = string_slice(name)
        argument_slice, argument_storage = string_slice(argument) if argument is not None else (ByteSlice(), None)
        status = library.cutrans_vm_command(handle, name_slice, argument_slice)
        if status != expected:
            raise RuntimeError(f"{name} returned {status}, expected {expected}")

    def export_png(handle: ctypes.c_void_p, filename: str, failure: int | None = None) -> bytes | None:
        name, name_storage = string_slice("editor.export.png")
        target, target_storage = string_slice(f"session://exports/{filename}")
        task_id = ctypes.c_uint64()
        admission = library.cutrans_vm_command_result(handle, name, target, ctypes.byref(task_id))
        # B1 validates Source versions before durable admission. Invalid input
        # must not publish an orphan task or touch the requested destination.
        if failure is not None and admission == 8:
            if task_id.value:
                raise RuntimeError("rejected snapshot export published a task ID")
            return None
        if admission != 1 or not task_id.value:
            raise RuntimeError("external-reference export was not accepted")
        status = library.cutrans_vm_pump(handle)
        if failure is not None:
            if status != failure:
                raise RuntimeError(f"external-reference export returned {status}, expected {failure}")
            return None
        if status != 0:
            raise RuntimeError(f"external-reference export failed with {status}")
        return (data_dir / "exports" / filename).read_bytes()

    handle = create()
    try:
        path_slice, path_storage = string_slice(str(source))
        asset_id = ctypes.c_uint64()
        if library.cutrans_vm_asset_open_external(handle, path_slice, ctypes.byref(asset_id)) != 1 or asset_id.value != 1:
            raise RuntimeError("could not authorize the original Source")
        command(handle, "editor.asset.insert", "1")
        command(handle, "doc.save")
        document = read_buffer(library, handle, "cutrans_vm_document_read").decode("utf-8")
        if not document.startswith("version=3\n") or "library://1" not in document or str(source) in document:
            raise RuntimeError("original Source reference leaked a host path or lost its stable id")
        catalog_text = (data_dir / "session/external-sources.json").read_text(encoding="utf-8")
        authorization = json.loads(catalog_text)
        if (authorization["format"] != "cutrans-external-sources/2"
                or authorization["sources"][0].get("identity_scheme") != "win32-file-id/1"
                or json.dumps(str(source)) not in catalog_text):
            raise RuntimeError("the Session did not retain the explicit external authorization")
        first_png = export_png(handle, "original.png")
    finally:
        library.cutrans_vm_destroy(handle)

    restored = create()
    try:
        listing = AssetListReport()
        if library.cutrans_vm_asset_list(restored, ctypes.byref(listing)) != 0 or listing.count != 0:
            raise RuntimeError("external authorization incorrectly revived the Station")
        if export_png(restored, "original.png") != first_png:
            raise RuntimeError("original Source export changed after restart")
        current_document = read_buffer(library, restored, "cutrans_vm_document_read").decode("utf-8")
        source_output = next(line.split("=", 1)[1] for line in current_document.splitlines() if line.startswith("output="))
        command(restored, "editor.invert.add", source_output)
        changed_png = export_png(restored, "changed-source.png")
        source.write_bytes(changed_png)
        command(restored, "library.refresh", "1")
        command(restored, "asset.open", "library://1", expected=1)
        listing = AssetListReport()
        if library.cutrans_vm_asset_list(restored, ctypes.byref(listing)) != 0 or listing.count == 0:
            raise RuntimeError("updated Source did not produce an active Asset")
        new_id = max(entry.handle for entry in listing.entries[: listing.count])
        _, new_content, _ = asset_projection(library, restored, new_id)
        if first_png == new_content or new_content != changed_png:
            raise RuntimeError("source update overwrote the active Asset instead of creating a version")
        # C1 retains the adopted A version. The document still means invert(A)
        # after the library head advances to B=the previously exported invert(A).
        # Evaluating against live B instead would incorrectly invert it twice.
        if export_png(restored, "retained-old.png") != changed_png:
            raise RuntimeError("library refresh changed the document's adopted Source version")
        command(restored, "editor.asset.insert", str(new_id))
        command(restored, "doc.save")
        if export_png(restored, "updated.png") != changed_png:
            raise RuntimeError("explicit Source version update did not take effect")
    finally:
        library.cutrans_vm_destroy(restored)

    source.unlink()
    missing = create()
    try:
        if export_png(missing, "retained-missing.png") != changed_png:
            raise RuntimeError("adopted library Source was lost with its original external file")
        # Browsing the current reference must still reveal the missing source;
        # retention does not silently detach the library's reference ownership.
        command(missing, "asset.open", "library://1", expected=8)
    finally:
        library.cutrans_vm_destroy(missing)
    (data_dir / "session/external-sources.json").write_text("not-json", encoding="utf-8")
    invalid = ctypes.c_void_p()
    if library.cutrans_vm_create(ctypes.byref(config), ctypes.byref(invalid)) != 8 or invalid.value:
        raise RuntimeError("corrupt external authorization was accepted or replaced")
    print("CUTRANS_EXTERNAL_REFERENCE_OK direct=1 restart=1 version=1 retained_missing=1 current_missing_rejected=1 corrupt_catalog=1")


def _verify_library_lifecycle(library: ctypes.WinDLL, runtime_dir: Path, root: Path, mode: str) -> None:
    data_dir = mark_data(root / "resource library data", mode, runtime_dir)
    source = root / "library-source.png"
    shutil.copyfile(runtime_dir / "assets/examples/pngtest.png", source)
    resource, resource_storage = string_slice(str(runtime_dir))
    data, data_storage = string_slice(str(data_dir))
    config = Config(ctypes.sizeof(Config), ABI_VERSION, 1 if mode == "portable" else 2, 0, resource, data)

    def create() -> ctypes.c_void_p:
        handle = ctypes.c_void_p()
        if library.cutrans_vm_create(ctypes.byref(config), ctypes.byref(handle)) != 0 or not handle.value:
            raise RuntimeError("could not create the resource-library Runtime")
        return handle

    def command(handle: ctypes.c_void_p, name: str, argument: str | None = None, expected: int = 0) -> None:
        name_slice, name_storage = string_slice(name)
        argument_slice, argument_storage = string_slice(argument) if argument is not None else (ByteSlice(), None)
        status = library.cutrans_vm_command(handle, name_slice, argument_slice)
        if status != expected:
            raise RuntimeError(f"{name} returned {status}, expected {expected}")

    def export_png(handle: ctypes.c_void_p, filename: str) -> bytes:
        name, name_storage = string_slice("editor.export.png")
        target, target_storage = string_slice(f"session://exports/{filename}")
        task_id = ctypes.c_uint64()
        if library.cutrans_vm_command_result(handle, name, target, ctypes.byref(task_id)) != 1 or not task_id.value or library.cutrans_vm_pump(handle) != 0:
            raise RuntimeError("library export failed")
        return (data_dir / "exports" / filename).read_bytes()

    handle = create()
    try:
        path_slice, path_storage = string_slice(str(source))
        for _ in range(2):
            asset_id = ctypes.c_uint64()
            if library.cutrans_vm_asset_open_external(handle, path_slice, ctypes.byref(asset_id)) != 1 or asset_id.value != 1:
                raise RuntimeError("library import did not deduplicate the resource")
        command(handle, "editor.asset.insert", "1")
        command(handle, "doc.save")
        document = read_buffer(library, handle, "cutrans_vm_document_read").decode("utf-8")
        if "library://1" not in document or str(source) in document:
            raise RuntimeError("library Source does not use a stable id")
        original_content = source.read_bytes()
        directory, labels = library_projection(library, handle, 1)
        if labels != ["library-source.png"] or directory.entries[0].kind != 1 or directory.entries[0].provenance != 0:
            raise RuntimeError("external import did not produce a labeled reference entry")
        if bytes(directory.entries[0].content_hash) != hashlib.sha256(original_content).digest():
            raise RuntimeError("reference entry has the wrong content hash")
        first_png = export_png(handle, "original.png")
        command(handle, "library.detach", "1")
        command(handle, "library.refresh", "1", expected=5)
        detached_directory, labels = library_projection(library, handle, 1)
        if detached_directory.revision <= directory.revision or detached_directory.entries[0].kind != 2 or detached_directory.entries[0].provenance != 2:
            raise RuntimeError("library detach did not update ownership and provenance")
        if bytes(detached_directory.entries[0].content_hash) != hashlib.sha256(original_content).digest():
            raise RuntimeError("library detach changed the resource identity")
        directory = detached_directory
        listing = AssetListReport()
        if library.cutrans_vm_asset_list(handle, ctypes.byref(listing)) != 0:
            raise RuntimeError("could not read library ownership projection")
        entry = next(entry for entry in listing.entries[: listing.count] if entry.library_id == 1)
        if entry.source_kind != 3 or entry.library_kind != 2:
            raise RuntimeError("library ownership projection did not change")
        command(handle, "library.create", "1 created.png")
        directory, labels = library_projection(library, handle, 2)
        if directory.revision <= detached_directory.revision or labels != ["library-source.png", "created.png"]:
            raise RuntimeError("created library entry is not visible before loading")
        created = directory.entries[1]
        if created.id != 2 or created.kind != 2 or created.provenance != 1 or bytes(created.content_hash) != hashlib.sha256(original_content).digest():
            raise RuntimeError("created library entry has invalid ownership, provenance, or content")
        if read_buffer(library, handle, "cutrans_vm_library_label", 2) != b"created.png":
            raise RuntimeError("library label ABI did not read the unopened entry")
        if library.cutrans_vm_library_label(handle, 99, None, 0, None) != 13:
            raise RuntimeError("library label ABI did not reject an unknown id")
        command(handle, "library.folder.create", "0 素材")
        command(handle, "library.folder.create", "3 角色")
        command(handle, "library.move", "2 4")
        command(handle, "library.rename", "4 主角")
        command(handle, "library.rename", "2 renamed.png")
        command(handle, "library.folder.create", "0 素材")
        directory, labels = library_projection(library, handle, 5)
        expected_labels = ["素材", "主角", "素材", "library-source.png", "renamed.png"]
        if labels != expected_labels or directory.entries[0].id == directory.entries[2].id:
            raise RuntimeError("folder labels were confused with stable ids")
        if directory.entries[0].parent_id != 0 or directory.entries[1].parent_id != 3 or directory.entries[4].parent_id != 4:
            raise RuntimeError("logical parent ids were not projected")
        if directory.entries[4].node_kind != 2 or directory.entries[4].kind != 2 or directory.entries[4].provenance != 1:
            raise RuntimeError("folder operations changed resource metadata")
        listing = AssetListReport()
        if library.cutrans_vm_asset_list(handle, ctypes.byref(listing)) != 0 or listing.count != 1:
            raise RuntimeError("folder operations incorrectly loaded an Asset")
        command(handle, "library.move", "3 4", expected=5)
        command(handle, "library.move", "2 99", expected=5)
        command(handle, "library.move", "2 1", expected=5)
        command(handle, "library.folder.create", "4 bad/name", expected=3)
        command(handle, "asset.open", "library://3", expected=8)
        command(handle, "asset.open", "library://2", expected=1)
        _, created_content, created_uri = asset_projection(library, handle, 2)
        if created_uri != "library://2" or created_content != original_content:
            raise RuntimeError("moving or renaming changed the library content or identity")
        command(handle, "editor.asset.insert", "2")
        command(handle, "doc.save")
        document = read_buffer(library, handle, "cutrans_vm_document_read").decode("utf-8")
        if "library://2" not in document or "renamed.png" in document or "主角" in document:
            raise RuntimeError("document persisted a logical path instead of the stable id")
        source.unlink()
        if export_png(handle, "original.png") != first_png:
            raise RuntimeError("detached library content depends on the original file")
    finally:
        library.cutrans_vm_destroy(handle)

    restored = create()
    try:
        listing = AssetListReport()
        if library.cutrans_vm_asset_list(restored, ctypes.byref(listing)) != 0 or listing.count != 0:
            raise RuntimeError("library Station unexpectedly survived restart")
        directory, labels = library_projection(library, restored, 5)
        if labels != expected_labels or directory.entries[1].parent_id != 3 or directory.entries[4].parent_id != 4:
            raise RuntimeError("library hierarchy did not survive an empty-Station restart")
        if directory.entries[3].provenance != 2 or directory.entries[4].provenance != 1:
            raise RuntimeError("library provenance did not survive restart")
        command(restored, "asset.open", "library://1", expected=1)
        info, content, source_uri = asset_projection(library, restored, 1)
        if source_uri != "library://1" or content != original_content or info.media_kind != 1 or info.coverage != 1:
            raise RuntimeError("owned library content did not restore")
        command(restored, "library.refresh", "1", expected=5)
        if export_png(restored, "original.png") != first_png:
            raise RuntimeError("restored library content changed")
        owned_version = check_root(data_dir / "library/versions/1" / f"{hashlib.sha256(original_content).hexdigest()}.bin")
        if not owned_version.is_file() or owned_version.read_bytes() != original_content:
            raise RuntimeError("new owned resource did not use immutable version storage")
        owned_version.write_bytes(b"tampered")
        library_projection(library, restored, 5)
        command(restored, "asset.open", "library://1", expected=8)
    finally:
        library.cutrans_vm_destroy(restored)
    catalog_path = data_dir / "library/catalog.json"
    catalog_text = catalog_path.read_text(encoding="utf-8")
    manifest = json.loads(catalog_text)
    if manifest["format"] != "cutrans-resource-library/2" or len(manifest["folders"]) != 3:
        raise RuntimeError("physical catalog does not contain the logical folder tree")
    manifest["folders"][0]["parent_id"] = 4
    catalog_path.write_text(json.dumps(manifest), encoding="utf-8")
    invalid = ctypes.c_void_p()
    if library.cutrans_vm_create(ctypes.byref(config), ctypes.byref(invalid)) != 8 or invalid.value:
        raise RuntimeError("folder cycle was accepted")
    manifest["folders"][0]["parent_id"] = 99
    catalog_path.write_text(json.dumps(manifest), encoding="utf-8")
    if library.cutrans_vm_create(ctypes.byref(config), ctypes.byref(invalid)) != 8 or invalid.value:
        raise RuntimeError("orphan folder was accepted")
    catalog_path.write_text("not-json", encoding="utf-8")
    if library.cutrans_vm_create(ctypes.byref(config), ctypes.byref(invalid)) != 8 or invalid.value:
        raise RuntimeError("corrupt library catalog was accepted or replaced")
    if catalog_path.read_text(encoding="utf-8") != "not-json":
        raise RuntimeError("invalid catalog was silently repaired")
    print("CUTRANS_LIBRARY_OK reference=1 detach=1 id_preserved=1 restore=1 create=1 catalog_unloaded=1 provenance=1 restart_catalog=1 folders=1 folder_ids=1 rename=1 move=1 cycle_rejected=1 orphan_rejected=1 tamper_rejected=1 corrupt_catalog=1")


def _verify_snapshot_lifecycle(library: ctypes.WinDLL, runtime_dir: Path, root: Path, mode: str) -> None:
    data_dir = mark_data(root / "snapshot data", mode, runtime_dir)
    source = root / "lifecycle-source.png"
    shutil.copyfile(runtime_dir / "assets/examples/pngtest.png", source)
    resource, resource_storage = string_slice(str(runtime_dir))
    data, data_storage = string_slice(str(data_dir))
    config = Config(ctypes.sizeof(Config), ABI_VERSION, 1 if mode == "portable" else 2, 0, resource, data)

    def create() -> ctypes.c_void_p:
        handle = ctypes.c_void_p()
        if library.cutrans_vm_create(ctypes.byref(config), ctypes.byref(handle)) != 0 or not handle.value:
            raise RuntimeError("could not create the snapshot Runtime")
        return handle

    def command(handle: ctypes.c_void_p, name: str, argument: str | None = None, expected: int = 0) -> None:
        name_slice, name_storage = string_slice(name)
        argument_slice, argument_storage = string_slice(argument) if argument is not None else (ByteSlice(), None)
        status = library.cutrans_vm_command(handle, name_slice, argument_slice)
        if status != expected:
            raise RuntimeError(f"{name} returned {status}, expected {expected}")

    def export_png(handle: ctypes.c_void_p, filename: str, failure: int | None = None) -> bytes | None:
        name, name_storage = string_slice("editor.export.png")
        target, target_storage = string_slice(f"session://exports/{filename}")
        task_id = ctypes.c_uint64()
        admission = library.cutrans_vm_command_result(handle, name, target, ctypes.byref(task_id))
        # B1 refuses unavailable/mismatched Sources before allocating a task.
        # Command.Code uses failed=8 for validation; no output may be written.
        if failure is not None and admission == 8:
            if task_id.value:
                raise RuntimeError("rejected snapshot export published a task ID")
            return None
        if admission != 1 or not task_id.value:
            raise RuntimeError("snapshot export was not accepted")
        status = library.cutrans_vm_pump(handle)
        if failure is not None:
            if status != failure:
                raise RuntimeError(f"snapshot export returned {status}, expected {failure}")
            return None
        if status != 0:
            raise RuntimeError(f"snapshot export failed with {status}")
        return (data_dir / "exports" / filename).read_bytes()

    handle = create()
    try:
        source_slice, source_storage = string_slice(str(source))
        relative, relative_storage = string_slice("relative.png")
        if library.cutrans_vm_asset_open_external(handle, relative, None) != 3:
            raise RuntimeError("external import accepted a host-relative path")
        for _ in range(2):
            asset_id = ctypes.c_uint64()
            if library.cutrans_vm_asset_open_external(handle, source_slice, ctypes.byref(asset_id)) != 1 or asset_id.value != 1:
                raise RuntimeError("external import did not reuse its Asset handle")
        original = source.read_bytes()
        source.unlink()
        info, content, source_uri = asset_projection(library, handle, 1)
        if not source_uri.startswith("library://") or content != original:
            raise RuntimeError("external preview depends on the deleted host file")
        command(handle, "editor.asset.insert", "1")
        command(handle, "asset.export", "1 session://snapshots/managed")
        command(handle, "asset.open", "session://snapshots/managed", expected=1)
        info, content, source_uri = asset_projection(library, handle, 2)
        if source_uri != "session://snapshots/managed" or content != original:
            raise RuntimeError("managed snapshot does not own the original content")
        digest = bytes(info.content_hash).hex()
        command(handle, "editor.asset.insert", "2")
        command(handle, "history.undo")
        command(handle, "history.redo")
        current_document = read_buffer(library, handle, "cutrans_vm_document_read").decode("utf-8")
        source_output = next(line.split("=", 1)[1] for line in current_document.splitlines() if line.startswith("output="))
        command(handle, "editor.invert.add", source_output)
        current_document = read_buffer(library, handle, "cutrans_vm_document_read").decode("utf-8")
        inverted_output = next(line.split("=", 1)[1] for line in current_document.splitlines() if line.startswith("output="))
        command(handle, "editor.resize.add", inverted_output + " 182 138")
        command(handle, "doc.save")
        document = read_buffer(library, handle, "cutrans_vm_document_read").decode("utf-8")
        if not document.startswith("version=3\n") or source_uri not in document or digest not in document or "external://" in document or str(source) in document:
            raise RuntimeError("document does not contain a self-describing snapshot Source")
        command(handle, "asset.release", "2")
        first_png = export_png(handle, "snapshot.png")
        assert first_png is not None
        if first_png[:8] != b"\x89PNG\r\n\x1a\n" or first_png[16:24] != (182).to_bytes(4, "big") + (138).to_bytes(4, "big"):
            raise RuntimeError("snapshot export has invalid PNG dimensions")
        command(handle, "asset.release", "1")
        command(handle, "asset.release", "1")
        listing = AssetListReport()
        if library.cutrans_vm_asset_list(handle, ctypes.byref(listing)) != 0 or listing.count != 0:
            raise RuntimeError("export leaked its Source lease")
    finally:
        library.cutrans_vm_destroy(handle)

    restored = create()
    try:
        listing = AssetListReport()
        if library.cutrans_vm_asset_list(restored, ctypes.byref(listing)) != 0 or listing.count != 0:
            raise RuntimeError("snapshot Station unexpectedly survived restart")
        document = read_buffer(library, restored, "cutrans_vm_document_read").decode("utf-8")
        if "session://snapshots/managed" not in document or digest not in document:
            raise RuntimeError("snapshot Source did not survive restart")
        restored_png = export_png(restored, "snapshot.png")
        if restored_png != first_png:
            raise RuntimeError("restored snapshot export differs from the original export")
        managed = data_dir / "snapshots/managed"
        tampered = data_dir / "tampered"
        shutil.copytree(managed, tampered)
        (tampered / "content.bin").write_bytes(b"tampered")
        command(restored, "asset.open", "session://tampered", expected=8)
        wrong_text = read_buffer(library, restored, "cutrans_vm_document_read").decode("utf-8").replace(digest, "0" * 64)
        (data_dir / "wrong.cut").write_text(wrong_text, encoding="utf-8")
        command(restored, "doc.open", "session://wrong.cut")
        if export_png(restored, "wrong-hash.png", failure=8) is not None or (data_dir / "exports/wrong-hash.png").exists():
            raise RuntimeError("mismatched Source hash produced an export")
    finally:
        library.cutrans_vm_destroy(restored)

    remove(data_dir / "snapshots/managed")
    missing = create()
    try:
        if export_png(missing, "missing.png", failure=13) is not None or (data_dir / "exports/missing.png").exists():
            raise RuntimeError("missing snapshot produced an export")
    finally:
        library.cutrans_vm_destroy(missing)
    print("CUTRANS_ASSET_SOURCE_OK external=1 snapshot=1 export=1 restart=1 missing=1 mismatch=1")


def verify(runtime_dir: Path, bootstrap: Path, mode: str, root: Path) -> None:
    output = run([
        sys.executable,
        str(Path(__file__).resolve()),
        "--runtime-dir",
        str(runtime_dir.resolve()),
        "--bootstrap",
        str(bootstrap.resolve()),
        "--mode",
        mode,
        "--root",
        str(check_root(root)),
    ])
    if "CUTRANS_ASSET_WORKSPACE_OK" not in output:
        raise RuntimeError("isolated asset probe did not report success")


def _verify(runtime_dir: Path, bootstrap: Path, mode: str, root: Path) -> None:
    runtime_dir = runtime_dir.resolve()
    bootstrap = bootstrap.resolve()
    root = check_root(root)
    if root.exists():
        raise RuntimeError(f"asset verification root must be new: {root}")
    if mode not in {"portable", "installed"}:
        raise RuntimeError(f"unsupported verification mode: {mode}")
    manifest = json.loads((runtime_dir / "runtime-pack.json").read_text(encoding="utf-8"))
    if manifest["host_api"] != ABI_VERSION:
        raise RuntimeError("asset commands require the current native ABI")
    if mode == "portable" and (runtime_dir.parent / "data").exists():
        raise RuntimeError("portable staging already contains user data")
    claim(root)
    before = hashes(runtime_dir)
    data_dir = mark_data(root / "asset data", mode, runtime_dir)
    library = ctypes.WinDLL(str(runtime_dir / "cutrans_vm_runtime.dll"))
    library.cutrans_vm_create.argtypes = [ctypes.POINTER(Config), ctypes.POINTER(ctypes.c_void_p)]
    library.cutrans_vm_create.restype = ctypes.c_int32
    library.cutrans_vm_destroy.argtypes = [ctypes.c_void_p]
    library.cutrans_vm_destroy.restype = None
    library.cutrans_vm_command.argtypes = [ctypes.c_void_p, ByteSlice, ByteSlice]
    library.cutrans_vm_command.restype = ctypes.c_int32
    library.cutrans_vm_grant_external.argtypes = [ctypes.c_void_p, ByteSlice, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint64)]
    library.cutrans_vm_grant_external.restype = ctypes.c_int32
    library.cutrans_vm_abi_version.restype = ctypes.c_uint32
    if library.cutrans_vm_abi_version() != ABI_VERSION:
        raise RuntimeError(f"asset projection requires Runtime ABI {ABI_VERSION}")
    library.cutrans_vm_library_list.argtypes = [ctypes.c_void_p, ctypes.POINTER(LibraryListReport)]
    library.cutrans_vm_library_list.restype = ctypes.c_int32
    library.cutrans_vm_library_label.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_char), ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    library.cutrans_vm_library_label.restype = ctypes.c_int32
    library.cutrans_vm_asset_list.argtypes = [ctypes.c_void_p, ctypes.POINTER(AssetListReport)]
    library.cutrans_vm_asset_list.restype = ctypes.c_int32
    library.cutrans_vm_asset_preview.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(AssetInfo)]
    library.cutrans_vm_asset_preview.restype = ctypes.c_int32
    library.cutrans_vm_asset_open_external.argtypes = [ctypes.c_void_p, ByteSlice, ctypes.POINTER(ctypes.c_uint64)]
    library.cutrans_vm_asset_open_external.restype = ctypes.c_int32
    library.cutrans_vm_command_result.argtypes = [ctypes.c_void_p, ByteSlice, ByteSlice, ctypes.POINTER(ctypes.c_uint64)]
    library.cutrans_vm_command_result.restype = ctypes.c_int32
    library.cutrans_vm_pump.argtypes = [ctypes.c_void_p]
    library.cutrans_vm_pump.restype = ctypes.c_int32
    for name in ("cutrans_vm_asset_source", "cutrans_vm_asset_read"):
        function = getattr(library, name)
        function.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_char), ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
        function.restype = ctypes.c_int32
    library.cutrans_vm_document_read.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char), ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    library.cutrans_vm_document_read.restype = ctypes.c_int32
    resource, resource_storage = string_slice(str(runtime_dir))
    data, data_storage = string_slice(str(data_dir))
    config = Config(ctypes.sizeof(Config), ABI_VERSION, 1 if mode == "portable" else 2, 0, resource, data)
    handle = ctypes.c_void_p()
    if library.cutrans_vm_create(ctypes.byref(config), ctypes.byref(handle)) != 0 or not handle.value:
        raise RuntimeError("could not create the distributed Runtime")

    def command(name: str, argument: str | None = None, expected: int = 0) -> None:
        name_slice, name_storage = string_slice(name)
        if argument is None:
            argument_slice = ByteSlice()
            argument_storage = None
        else:
            argument_slice, argument_storage = string_slice(argument)
        status = library.cutrans_vm_command(handle, name_slice, argument_slice)
        if status != expected:
            raise RuntimeError(f"{name} returned {status}, expected {expected}")

    try:
        source = root / "external-source.png"
        shutil.copyfile(runtime_dir / "assets/examples/pngtest.png", source)
        source_uri, source_uri_storage = string_slice(str(source))
        grant = ctypes.c_uint64()
        if library.cutrans_vm_grant_external(handle, source_uri, 0, ctypes.byref(grant)) != 0 or grant.value != 1:
            raise RuntimeError("could not grant the external source")
        command("asset.open", "external://1", expected=1)
        command("asset.open", "external://1", expected=1)
        original = (runtime_dir / "assets/examples/pngtest.png").read_bytes()
        source.unlink()
        info, content, source_uri = asset_projection(library, handle, 1)
        if (info.width, info.height, source_uri, content) != (91, 69, "external://1", original):
            raise RuntimeError("external asset projection changed after its source was removed")
        command("asset.preview", "1")
        command("asset.export", "1 session://snapshots/one")
        command("asset.export", "1 session://snapshots/one")
        command("asset.export", "1 pack://forbidden", expected=4)
        command("asset.release", "1")
        command("asset.release", "1")
        command("asset.release", "1", expected=5)
        command("asset.preview", "99", expected=5)
        command("asset.open", "session://snapshots/one", expected=1)
        command("asset.preview", "2")
        command("asset.list")
        snapshot = data_dir / "snapshots/one"
        manifest_text = (snapshot / "snapshot.json").read_text(encoding="utf-8")
        snapshot_manifest = json.loads(manifest_text)
        if snapshot_manifest["format"] != "cutrans-content-snapshot/1":
            raise RuntimeError("snapshot is not a Content Snapshot")
        if (snapshot / "content.bin").read_bytes() != original:
            raise RuntimeError("snapshot content differs from the source")
        digest = hashlib.sha256(original).hexdigest()
        if snapshot_manifest["snapshot_id"] != digest or snapshot_manifest["content"]["sha256"] != digest or snapshot_manifest["content"]["byteLength"] != len(original):
            raise RuntimeError("snapshot identity or content length is invalid")
        if str(root) in manifest_text or root.as_posix() in manifest_text:
            raise RuntimeError("snapshot leaked a host path")
        tampered = data_dir / "tampered"
        shutil.copytree(snapshot, tampered)
        (tampered / "content.bin").write_bytes(b"tampered")
        command("asset.open", "session://tampered", expected=8)
        command("asset.export", "2 session://tampered", expected=5)
        command("editor.asset.insert", "1", expected=5)
        command("editor.asset.insert", "2")
        command("asset.open", "pack://assets/examples/pngtest.png", expected=1)
        info, content, source_uri = asset_projection(library, handle, 3)
        if (info.width, info.height, source_uri, content) != (91, 69, "pack://assets/examples/pngtest.png", original):
            raise RuntimeError("Pack asset projection is invalid")
        listing = AssetListReport()
        if library.cutrans_vm_asset_list(handle, ctypes.byref(listing)) != 0 or listing.abi_version != ABI_VERSION or listing.count != 2:
            raise RuntimeError("asset list projection is invalid")
        if not any(entry.handle == 3 and entry.leases == 1 and entry.source_kind == 0 for entry in listing.entries[: listing.count]):
            raise RuntimeError("asset list projection does not contain the Pack source")
        command("editor.asset.insert", "3")
        document = read_buffer(library, handle, "cutrans_vm_document_read").decode("utf-8")
        if source_uri not in document or "asset://" in document:
            raise RuntimeError("document did not persist a stable Source URI")
        command("history.undo")
        if source_uri in read_buffer(library, handle, "cutrans_vm_document_read").decode("utf-8"):
            raise RuntimeError("asset insert was not undone")
        command("history.redo")
        if source_uri not in read_buffer(library, handle, "cutrans_vm_document_read").decode("utf-8"):
            raise RuntimeError("asset insert was not redone")
        command("doc.save")
    finally:
        library.cutrans_vm_destroy(handle)
    restored = ctypes.c_void_p()
    if library.cutrans_vm_create(ctypes.byref(config), ctypes.byref(restored)) != 0 or not restored.value:
        raise RuntimeError("could not restore the source document")
    try:
        listing = AssetListReport()
        if library.cutrans_vm_asset_list(restored, ctypes.byref(listing)) != 0 or listing.count != 0:
            raise RuntimeError("ephemeral Station unexpectedly survived the restart")
        document = read_buffer(library, restored, "cutrans_vm_document_read").decode("utf-8")
        if "pack://assets/examples/pngtest.png" not in document or "asset://" in document:
            raise RuntimeError("stable source document did not survive the restart")
    finally:
        library.cutrans_vm_destroy(restored)
    _verify_snapshot_lifecycle(library, runtime_dir, root, mode)
    _verify_external_reference(library, runtime_dir, root, mode)
    _verify_library_lifecycle(library, runtime_dir, root, mode)
    if hashes(runtime_dir) != before or (runtime_dir / "data").exists():
        raise RuntimeError("asset verification modified the Runtime Pack")
    if mode == "portable" and (runtime_dir.parent / "data").exists():
        raise RuntimeError("asset verification polluted portable staging")
    retain(root)
    print("CUTRANS_ASSET_WORKSPACE_OK open=1 reuse=1 export=1 restore=1 tamper_rejected=1 insert=1 history=1 source_restart=1")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-dir", type=Path, default=OUTPUT / "portable/runtime")
    parser.add_argument("--bootstrap", type=Path, default=OUTPUT / "portable/cutrans_bootstrap.exe")
    parser.add_argument("--mode", choices=("portable", "installed"), default="portable")
    parser.add_argument("--root", type=Path, default=default_root("asset-user"))
    args = parser.parse_args()
    _verify(args.runtime_dir, args.bootstrap, args.mode, args.root)


if __name__ == "__main__":
    main()
