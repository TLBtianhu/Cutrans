"""C2c2 ordinary-file registration and independent delivery on real DLL/Host.

Every input, replacement, link and failed-attempt report is retained below a
claimed synthetic case. No GUI, installer, system registration or real input.
The loaded DLL and the Host always belong to the same tested artifact tree.
"""
from __future__ import annotations

import argparse
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import sys

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from product import identity
from verification_paths import check_root, claim, default_root, retain
from verify_assets import AssetInfo, AssetListReport, read_buffer
from verify_edit_commit import exclusive_file
from verify_host import invoke, run
from verify_input import hashes, string_slice
from verify_jobs import ACCEPTED, FAILED, OK, require, tiny_png
from verify_resident_resources import station, station_report
from verify_resource_operations import (CANDIDATE_CHANGED, RESOURCE_API_VERSION, WRONG_EPOCH,
    Native, Outcome, ProbeRequest, Proof, configure, host_apply, host_request,
    host_view, known, preserve, request, resource_files, unpack_proof)
from verify_resource_versions import (COLOR_A, assert_output, assert_projection,
    document_state, history_bytes, host_asset_bytes, host_legacy, host_rpc,
    retained_files, row)
from verify_workspace import Stamp
from verify_workspace_rpc import Workspace

REGISTER, DENIED, INVALID, ABI_MISMATCH = 3, 4, 3, 11
TEXT = "Cutrans ordinary source: 文本不是图片。\nSecond line.\n".encode("utf-8")
UNKNOWN = b"\x00CUTRANS-owned-unknown\xff\x80\x01\x00\r\n" + bytes(range(256))


def sha(content):
    return hashlib.sha256(content).hexdigest()


def resource(view, resource_id):
    matches = [item for item in view["body"]["resources"] if item["id"] == resource_id]
    require(len(matches) == 1, "registered ResourceRef did not identify one catalog entry")
    return matches[0]


def assert_reference(view, resource_id, content, path):
    item = resource(view, resource_id)
    require(item["kind"] == "reference" and item["provenance"] == "external"
        and item["source"].startswith("external://") and item["sha256"] == sha(content)
        and item["label"] == path.name and item["parent_id"] == 0,
        "ordinary registration changed content, display identity or reference ownership")
    return item


def authorizations(data):
    path = check_root(data / "session/external-sources.json")
    return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else None


def readonly(path):
    path = check_root(path)
    kernel = c.WinDLL("kernel32", use_last_error=True)
    kernel.GetFileAttributesW.argtypes, kernel.GetFileAttributesW.restype = [c.c_wchar_p], c.c_uint32
    kernel.SetFileAttributesW.argtypes, kernel.SetFileAttributesW.restype = [c.c_wchar_p, c.c_uint32], c.c_int32
    old = kernel.GetFileAttributesW(str(path))
    require(old != 0xFFFFFFFF, "owned read-only source attributes were unavailable")
    require(kernel.SetFileAttributesW(str(path), old | 1) != 0, "owned source could not become read-only")
    require(kernel.GetFileAttributesW(str(path)) & 1, "owned source is not actually read-only")
    return kernel


def register(runtime, path, content, client):
    before, before_files, before_station = runtime.view(), resource_files(runtime.data), station(runtime)[1]
    proof = runtime.probe(path, mode=REGISTER, target=0)
    require(not any(proof.head_hash) and bytes(proof.content_hash).hex() == sha(content)
        and proof.byte_length == len(content) and proof.file_index > 0,
        "registration probe did not bind exact ordinary bytes and actual file identity")
    require(runtime.view() == before and resource_files(runtime.data) == before_files
        and station(runtime)[1] == before_station, "registration probe created authorization, bytes or Station state")
    operation = request(proof, path, client=client)
    outcome = runtime.apply(operation, disposition=1)
    after = runtime.view()
    require(outcome.resource_id > 0 and outcome.resource_id == before["body"]["next_id"]
        and outcome.stamp.epoch_hi == proof.stamp.epoch_hi and outcome.stamp.epoch_lo == proof.stamp.epoch_lo
        and outcome.stamp.revision == proof.stamp.revision + 1
        and len(after["body"]["resources"]) == len(before["body"]["resources"]) + 1
        and station(runtime)[1] == before_station,
        "registration did not publish one new ID independently of delivery")
    assert_reference(after, outcome.resource_id, content, path)
    declarations = resource_files(runtime.data)
    duplicate = runtime.apply(operation, disposition=2)
    require(known(duplicate) == {**known(outcome), "disposition": 2} and runtime.view() == after
        and resource_files(runtime.data) == declarations, "duplicate registration created a second ID/grant or reread state")
    return outcome.resource_id, operation


def acquire(runtime, resource_id, content):
    runtime.legacy("resource.acquire", f"{resource_id} {sha(content)}", ACCEPTED)
    entries = station(runtime)[1]
    matches = [handle for handle, item in entries.items()
        if item["library_id"] == resource_id and item["hash"] == sha(content)]
    require(len(matches) == 1, "generic acquisition did not expose one exact ResourceRef in Station")
    handle = matches[0]
    require(entries[handle]["size"] == len(content)
        and read_buffer(runtime.library, runtime.handle, "cutrans_vm_asset_read", handle) == content
        and read_buffer(runtime.library, runtime.handle, "cutrans_vm_asset_source", handle).decode() == f"library://{resource_id}",
        "generic delivery did not return complete uninterpreted bytes")
    before = station(runtime)
    runtime.legacy("resource.acquire", f"{resource_id} {sha(content)}", ACCEPTED)
    require(station(runtime) == before, "duplicate generic delivery grew a remote root lease")
    return handle


def reject_image_consumer(runtime, handle, resource_id, content):
    before_doc, before_history, before_catalog, before_station = (
        document_state(runtime), history_bytes(runtime.data), runtime.view(), station(runtime))
    info = AssetInfo()
    require(runtime.library.cutrans_vm_asset_preview(runtime.handle, handle, c.byref(info)) == FAILED,
        "non-image ordinary bytes were presented as a valid image preview")
    runtime.submit_edit("editor.asset.insert", str(handle), FAILED)
    require(document_state(runtime) == before_doc and history_bytes(runtime.data) == before_history
        and runtime.view() == before_catalog and station(runtime) == before_station
        and resource(before_catalog, resource_id)["sha256"] == sha(content)
        and read_buffer(runtime.library, runtime.handle, "cutrans_vm_asset_read", handle) == content,
        "image consumer refusal erased a ResourceRef or changed accepted work/bytes")


def native_types(dll, runtime_dir, root, evidence):
    case = check_root(root / "native-types")
    case.mkdir()
    text_dir = check_root(case / "含中文 空格目录")
    text_dir.mkdir()
    sources = [(case / "old-work.png", tiny_png(COLOR_A)), (text_dir / "只读 笔记.txt", TEXT),
        (case / "unknown.cutrans-test", UNKNOWN), (case / "empty-file.bin", b""),
        (case / "exact-16MiB.bin", b"0123456789ABCDEF" * (1024 * 1024))]
    for path, content in sources:
        path.write_bytes(content)
    kernel = readonly(sources[1][0])
    runtime = Native(dll, runtime_dir, case / "data", evidence)
    references, old_epoch = [], None
    try:
        resource_id, png_operation = register(runtime, *sources[0], client=(0xC2C201, 1))
        require(not retained_files(runtime.data) and not station(runtime)[1], "reference registration copied durable bytes or loaded Station")
        png_handle = acquire(runtime, resource_id, sources[0][1])
        assert_projection(runtime, png_handle, sources[0][1], resource_id)
        runtime.submit_edit("editor.asset.insert", str(png_handle))
        task_id = runtime.submit_edit("editor.export.png", "session://exports/old-work.png", ACCEPTED).task_id
        frozen_doc, frozen_history, frozen_jobs = document_state(runtime), history_bytes(runtime.data), runtime.all_jobs()
        old_entry = dict(resource(runtime.view(), resource_id))
        references.append((resource_id, *sources[0]))
        for index, (path, content) in enumerate(sources[1:], 2):
            before_versions = retained_files(runtime.data)
            new_id, old_epoch = register(runtime, path, content, client=(0xC2C201, index))
            require(retained_files(runtime.data) == before_versions, "generic reference registration persisted a copy of source bytes")
            generic_handle = acquire(runtime, new_id, content)
            reject_image_consumer(runtime, generic_handle, new_id, content)
            require(document_state(runtime) == frozen_doc and history_bytes(runtime.data) == frozen_history
                and runtime.all_jobs() == frozen_jobs and resource(runtime.view(), resource_id) == old_entry,
                "registering another type rewrote an older resource/document/queued JobSpec")
            assert_projection(runtime, png_handle, sources[0][1], resource_id)
            references.append((new_id, path, content))
        before = runtime.view()
        files = resource_files(runtime.data)
        replayed = runtime.apply(png_operation, disposition=2)
        text_proof = runtime.probe(sources[1][0], REGISTER, 0)
        same_file = runtime.apply(request(text_proof, sources[1][0], client=(0xC2C201, 99)), disposition=1)
        require(replayed.resource_id == resource_id and same_file.resource_id == references[1][0]
            and same_file.stamp.revision == text_proof.stamp.revision and runtime.view() == before
            and resource_files(runtime.data) == files and document_state(runtime) == frozen_doc
            and history_bytes(runtime.data) == frozen_history and runtime.all_jobs() == frozen_jobs,
            "old receipt replay or new-token same-file registration duplicated a resource or rewrote work")
        evidence["checks"].append("DLL_TXT_PNG_unknown_empty_exact_16MiB_bytes_and_Chinese_space_paths_register_and_deliver_exact_ResourceRef_bytes")
        evidence["checks"].append("old_registration_receipt_precedes_newer_catalog_CAS_and_new_token_same_file_returns_existing_ID_without_publish")
        evidence["checks"].append("image_consumer_rejection_preserves_registered_ID_bytes_and_older_document_queued_JobSpec")

        auth = authorizations(runtime.data)
        require(auth["format"] == "cutrans-external-sources/2" and len(auth["sources"]) == len(sources)
            and all(item["access"] == "read_only" and item["identity_scheme"] == "win32-file-id/1" for item in auth["sources"]),
            "ordinary registration did not create precisely read-only, physically identified authorizations")
        before_source, before_auth = sources[1][0].read_bytes(), (runtime.data / "session/external-sources.json").read_bytes()
        uri = resource(runtime.view(), references[1][0])["source"]
        # The legacy save command maps resolvePath(ReadOnlyResource) to its
        # established invalid_arguments result, rather than the new source
        # admission/acquire permission_denied result.
        runtime.legacy("doc.save", uri, INVALID)
        require(sources[1][0].read_bytes() == before_source and kernel.GetFileAttributesW(str(sources[1][0])) & 1
            and (runtime.data / "session/external-sources.json").read_bytes() == before_auth,
            "failed source write changed original bytes, read-only attribute or authorization")
        evidence["checks"].append("read_only_source_registers_successfully_and_grant_cannot_be_used_as_output")

        runtime.drain()
        evidence["old_job"] = {"task": row(runtime, task_id), "output": assert_output(row(runtime, task_id),
            runtime.data / "exports/old-work.png", COLOR_A)}
        final_body = runtime.view()["body"]
        evidence["native_registered_refs"] = [{"id": rid, "path": str(path), "sha256": sha(content), "size": len(content)}
            for rid, path, content in references]
    finally:
        runtime.close()
    runtime = Native(dll, runtime_dir, case / "data", evidence)
    try:
        require(runtime.view()["body"] == final_body and not station(runtime)[1],
            "cold restore lost ordinary declarations or reconstructed transient Station leases")
        result = runtime.apply(old_epoch, WRONG_EPOCH, disposition=3)
        require(result.resource_id == 0 and runtime.view()["body"] == final_body, "old-epoch registration duplicated a cold resource")
        for rid, path, content in references:
            handle = acquire(runtime, rid, content)
            if rid != resource_id:
                reject_image_consumer(runtime, handle, rid, content)
            require(path.read_bytes() == content, "cold delivery modified the original source")
        evidence["checks"].append("DLL_cold_restore_keeps_generic_declarations_reloads_bytes_and_rejects_old_epoch_registration")
    finally:
        runtime.close()


def native_failures(dll, runtime_dir, root, evidence):
    case = check_root(root / "native-failures")
    case.mkdir()
    initial, changed, replaced, candidate, missing = [case / name for name in (
        "initial.txt", "changed.bin", "same-hash-new-object.bin", "catalog-locked.txt", "delivery-missing.bin")]
    for path, content in ((initial, TEXT), (changed, UNKNOWN), (replaced, UNKNOWN), (candidate, TEXT + b"catalog"), (missing, UNKNOWN + b"missing")):
        path.write_bytes(content)
    runtime = Native(dll, runtime_dir, case / "data", evidence)
    try:
        register(runtime, initial, TEXT, client=(0xC2C202, 1))
        baseline, before_files = runtime.view(), resource_files(runtime.data)
        proof = runtime.probe(changed, REGISTER, 0)
        operation = request(proof, changed, client=(0xC2C202, 2))
        changed.write_bytes(UNKNOWN + b"changed after probe")
        result = runtime.apply(operation, CANDIDATE_CHANGED, 1)
        require(result.resource_id == 0 and runtime.view() == baseline and resource_files(runtime.data) == before_files,
            "changed registration candidate published identity or authorization")
        preserve(changed, case / "retired-changed-input.bin", evidence)
        runtime.apply(operation, CANDIDATE_CHANGED, 2)
        proof = runtime.probe(replaced, REGISTER, 0)
        preserve(replaced, case / "retired-original-file-object.bin", evidence)
        replaced.write_bytes(UNKNOWN)
        result = runtime.apply(request(proof, replaced, client=(0xC2C202, 3)), CANDIDATE_CHANGED, 1)
        require(result.resource_id == 0 and runtime.view() == baseline and resource_files(runtime.data) == before_files,
            "same bytes from a replacement file object passed the saved registration proof")
        evidence["checks"].append("registration_proof_rejects_changed_bytes_and_equal_hash_replacement_identity_and_receipts_failure_before_IO")

        catalog = check_root(runtime.data / "library/catalog.json")
        old_catalog = catalog.read_bytes()
        proof = runtime.probe(candidate, REGISTER, 0)
        operation = request(proof, candidate, client=(0xC2C202, 4))
        kernel, lock = exclusive_file(catalog)
        try:
            result = runtime.apply(operation, FAILED, 1)
            require(result.resource_id == 0 and runtime.view() == baseline and not station(runtime)[1],
                "failed catalog publication exposed an ID or live delivery")
        finally:
            kernel.CloseHandle(lock)
        require(catalog.read_bytes() == old_catalog and candidate.read_bytes() == TEXT + b"catalog"
            and not retained_files(runtime.data), "failed reference publication rewrote catalog/source or retained source bytes")
        evidence["catalog_failure_dependencies"] = {"before": before_files, "after": resource_files(runtime.data),
            "authorizations": authorizations(runtime.data), "policy": "unused read-only grant may remain; no catalog entry or source deletion"}
        preserve(candidate, case / "retired-catalog-candidate.txt", evidence)
        runtime.apply(operation, FAILED, 2)
        require(runtime.view() == baseline, "retrying a known catalog failure created a resource")
        evidence["checks"].append("catalog_lock_failure_preserves_ID_allocator_catalog_and_original_with_explicit_retained_dependency_evidence")

        rid, _ = register(runtime, missing, UNKNOWN + b"missing", client=(0xC2C202, 5))
        accepted_catalog = runtime.view()
        preserve(missing, case / "retired-missing-delivery.bin", evidence)
        runtime.legacy("resource.acquire", f"{rid} {sha(UNKNOWN + b'missing')}", FAILED)
        require(runtime.view() == accepted_catalog and not station(runtime)[1] and resource(accepted_catalog, rid)["id"] == rid,
            "delivery failure erased the successful registration or invented an asset")
        evidence["checks"].append("source_disappearing_after_registration_fails_delivery_without_erasing_successful_resource_ID")
    finally:
        runtime.close()
    runtime = Native(dll, runtime_dir, case / "data", evidence)
    try:
        require(runtime.view()["body"] == accepted_catalog["body"] and not station(runtime)[1],
            "cold restore erased an undeliverable resource or recreated transient Station state")
        runtime.legacy("resource.acquire", f"{rid} {sha(UNKNOWN + b'missing')}", FAILED)
        require(runtime.view()["body"] == accepted_catalog["body"] and not station(runtime)[1],
            "cold missing-source delivery changed the persistent registered identity")
        evidence["checks"].append("cold_restore_preserves_missing_source_registration_and_reports_delivery_failure_without_inventing_Station")
    finally:
        runtime.close()


def junction(link, target):
    link, target = check_root(link), check_root(target)
    require(not link.exists() and target.is_dir(), "junction fixture must use fresh owned paths")
    kernel = c.WinDLL("kernel32", use_last_error=True)
    kernel.GetSystemDirectoryW.argtypes, kernel.GetSystemDirectoryW.restype = [c.c_wchar_p, c.c_uint32], c.c_uint32
    buffer = c.create_unicode_buffer(32768)
    length = kernel.GetSystemDirectoryW(buffer, len(buffer))
    require(0 < length < len(buffer), "system cmd.exe path was unavailable")
    run([str(Path(buffer.value) / "cmd.exe"), "/d", "/c", "mklink", "/J", str(link), str(target)])
    require(getattr(link.lstat(), "st_file_attributes", 0) & 0x400 and link.resolve() == target.resolve(),
        "real junction fixture does not have its exact owned target")
    return link


def copy_runtime(source, target):
    target = check_root(target)
    require(not target.exists(), "alternate resource tree would overwrite evidence")
    target.mkdir()
    for item in sorted(source.rglob("*")):
        require(not item.is_symlink() and not (getattr(item.lstat(), "st_file_attributes", 0) & 0x400),
            "artifact resource copy must not follow links")
        output = check_root(target / item.relative_to(source))
        if item.is_dir():
            output.mkdir()
        else:
            shutil.copy2(item, output)
    require(hashes(source) == hashes(target), "alternate resource fixture differs from the tested Runtime Pack")


def native_boundaries(dll, runtime_dir, root, evidence):
    case = check_root(root / "native-boundaries")
    case.mkdir()
    alternate = case / "alternate-runtime"
    copy_runtime(runtime_dir, alternate)
    runtime = Native(dll, alternate, case / "data", evidence)
    try:
        target = check_root(runtime.data / "managed-source")
        target.mkdir()
        managed = target / "managed.txt"
        managed.write_bytes(TEXT)
        before, files = runtime.view(), resource_files(runtime.data)
        for path in (managed, alternate / "assets/examples/pngtest.png", runtime_dir / "cutrans_vm_runtime.dll",
                     runtime_dir.parent / "cutrans_vm.exe"):
            require(path.is_file(), f"managed boundary fixture is absent: {path}")
            runtime.probe(path, REGISTER, 0, status=DENIED)
        link = junction(case / "alias-to-managed", target)
        runtime.probe(link / managed.name, REGISTER, 0, status=DENIED)
        symlink = check_root(case / "symlink-alias.txt")
        try:
            os.symlink(managed, symlink)
        except OSError as error:
            if getattr(error, "winerror", None) != 1314:
                raise
            evidence["symlink_coverage"] = {"covered": False, "winerror": getattr(error, "winerror", None), "error": repr(error),
                "limitation": "real NTFS junction and hard-link checks still ran; symlink privilege is not inferred"}
        else:
            require(symlink.is_symlink() and symlink.resolve() == managed.resolve() and managed.stat().st_nlink == 1,
                "symbolic-link fixture must use an independently single-linked managed target")
            runtime.probe(symlink, REGISTER, 0, status=DENIED)
            evidence["symlink_coverage"] = {"covered": True, "path": str(symlink), "target": str(managed)}
        hardlink = check_root(case / "hardlink-alias.txt")
        os.link(managed, hardlink)
        require(os.path.samefile(managed, hardlink) and managed.stat().st_nlink >= 2,
            "hard-link fixture did not preserve one real file identity")
        runtime.probe(hardlink, REGISTER, 0, status=DENIED)
        require(runtime.view() == before and resource_files(runtime.data) == files and not station(runtime)[1]
            and managed.read_bytes() == TEXT and hardlink.read_bytes() == TEXT and hashes(alternate) == hashes(runtime_dir),
            "managed/alias rejection changed target bytes, artifacts, authorizations or business state")
        evidence["managed_boundary"] = {"data": str(runtime.data), "configured_resource": str(alternate),
            "loaded_runtime": str(runtime_dir / "cutrans_vm_runtime.dll"), "junction": str(link), "target": str(target),
            "hardlink": str(hardlink), "target_sha256": sha(TEXT), "all_fixtures_retained": True}
        evidence["checks"].append("data_configured_resource_actual_DLL_product_roots_and_real_junction_hardlink_aliases_are_denied_without_mutation")
    finally:
        runtime.close()


def native_versions(dll, runtime_dir, root, evidence):
    case = check_root(root / "native-api-version")
    case.mkdir()
    source = case / "versioned-input.txt"
    source.write_bytes(TEXT)
    runtime = Native(dll, runtime_dir, case / "data", evidence)
    try:
        before, files = runtime.view(), resource_files(runtime.data)
        path, storage = string_slice(str(source))
        query = ProbeRequest(c.sizeof(ProbeRequest), 1, Stamp(*before["stamp"]), 0, REGISTER, 0, path)
        output = Proof()
        require(runtime.resources.probe(runtime.handle, c.byref(query), c.byref(output)) == ABI_MISMATCH,
            "resource API v2 accepted a v1 probe layout/version")
        proof = runtime.probe(source, REGISTER, 0)
        operation = request(proof, source, client=(0xC2C203, 1))
        operation.api_version = 1
        outcome = Outcome()
        require(runtime.resources.submit(runtime.handle, c.byref(operation), c.byref(outcome)) == ABI_MISMATCH,
            "resource API v2 accepted a v1 submit layout/version")
        require(runtime.view() == before and resource_files(runtime.data) == files and not station(runtime)[1],
            "v1 resource ABI rejection had side effects")
        operation.api_version = RESOURCE_API_VERSION
        first = runtime.apply(operation, disposition=1)
        require(first.resource_id > 0 and len(runtime.view()["body"]["resources"]) == 1,
            "rejected v1 request consumed the valid v2 sequence")
        evidence["checks"].append("DLL_resource_v1_probe_and_submit_rejected_without_mutation_or_consuming_v2_sequence")
    finally:
        runtime.close()


def host_station(wire):
    status, value, payload = host_rpc(wire, 12)
    require(status == value == 0 and len(payload) == c.sizeof(AssetListReport), "Host returned an invalid Station report")
    return station_report(AssetListReport.from_buffer_copy(payload))


def host_probe_register(wire, path, expected=OK, version=RESOURCE_API_VERSION):
    before = host_view(wire)
    encoded = str(path).encode("utf-8")
    status, value, payload = host_rpc(wire, 27, struct.pack("<IIQQQQII", version, REGISTER,
        *before["stamp"], 0, len(encoded), 0) + encoded)
    require(status == expected and value == 0, f"Host register probe={status}, expected={expected}")
    if expected != OK:
        require(not payload, "rejected Host registration probe returned a proof")
        return None
    proof = unpack_proof(payload)
    require(proof.target_id == 0 and proof.mode == REGISTER and not any(proof.head_hash)
        and (proof.stamp.epoch_hi, proof.stamp.epoch_lo, proof.stamp.revision) == before["stamp"],
        "Host registration proof was not bound to its exact catalog observation")
    return proof


def host_acquire(wire, rid, content):
    host_legacy(wire, "resource.acquire", f"{rid} {sha(content)}", ACCEPTED)
    matches = [handle for handle, item in host_station(wire)[1].items()
        if item["library_id"] == rid and item["hash"] == sha(content)]
    require(len(matches) == 1 and host_asset_bytes(wire, matches[0]) == content,
        "Host generic acquisition did not deliver exact complete ResourceRef bytes")
    before = host_station(wire)
    host_legacy(wire, "resource.acquire", f"{rid} {sha(content)}", ACCEPTED)
    require(host_station(wire) == before, "Host repeated acquisition accumulated leases")
    return matches[0]


def host_case(console, root, evidence):
    case = check_root(root / "Host")
    case.mkdir()
    text_dir = check_root(case / "主机 中文目录")
    text_dir.mkdir()
    sources = [(text_dir / "普通 文件.txt", TEXT), (case / "image.png", tiny_png(COLOR_A)),
        (case / "unknown.blob", UNKNOWN), (case / "empty-file.bin", b"")]
    for path, content in sources:
        path.write_bytes(content)
    data, stopped = case / "data", True
    refs, old_epoch = [], None
    try:
        stopped = False
        _, started = invoke(console, "start", data, "portable")
        require(started["state"] == "running" and started["abi"] == identity()["host_api"], "isolated registration Host did not start")
        wire = Workspace(data, evidence)
        for index, (path, content) in enumerate(sources, 1):
            before, files = host_view(wire), resource_files(data)
            host_probe_register(wire, path, INVALID, version=1)
            require(host_view(wire) == before and resource_files(data) == files, "v1 Host probe mutated state")
            proof = host_probe_register(wire, path)
            require(bytes(proof.content_hash).hex() == sha(content) and proof.byte_length == len(content),
                "Host register proof changed ordinary bytes")
            operation = host_request(proof, path, (0xC2C204, index))
            v1 = bytearray(operation)
            struct.pack_into("<I", v1, 0, 1)
            status, value, body = host_rpc(wire, 28, bytes(v1))
            require(status == INVALID and value == 0 and not body and host_view(wire) == before
                and resource_files(data) == files, "v1 Host submit mutated state or returned a fake known result")
            # A complete settled response header, followed by a deliberately
            # lost body, models a caller with no Outcome rather than a retry
            # that happened to arrive before the first admission.
            host_apply(wire, operation, discard=True)
            result = host_apply(wire, operation)
            after = host_view(wire)
            require(result["disposition"] == 2 and result["resource_id"] > 0
                and result["resource_id"] == before["body"]["next_id"]
                and result["stamp"] == (*before["stamp"][:2], before["stamp"][2] + 1)
                and len(after["body"]["resources"]) == len(before["body"]["resources"]) + 1,
                "lost registration Outcome or earlier v1 refusal created a duplicate ID/consumed the sequence")
            rid = result["resource_id"]
            assert_reference(after, rid, content, path)
            declarations = resource_files(data)
            require(host_apply(wire, operation) == result and host_view(wire) == after
                and resource_files(data) == declarations, "Host repeated registration changed declarations")
            handle = host_acquire(wire, rid, content)
            doc, before_station = wire.snapshot(), host_station(wire)
            status, value, body = host_rpc(wire, 14, identity=handle)
            if index == 2:
                require(status == OK and value == 0 and len(body) == c.sizeof(AssetInfo), "PNG consumer did not accept a generically registered PNG")
                info = AssetInfo.from_buffer_copy(body)
                require(info.struct_size == c.sizeof(AssetInfo) and info.abi_version == identity()["host_api"]
                    and info.handle == handle and bytes(info.content_hash).hex() == sha(content)
                    and info.width == info.height == 1 and info.media_kind == info.coverage == 1 and info.reserved == 0,
                    "PNG consumer metadata does not match the delivered ResourceRef")
            else:
                require(status == FAILED and value == 0 and not body, "Host image consumer accepted non-image bytes")
                outcome = wire.submit(wire.request((0xC2C205, index), 1, doc["stamp"], "editor.asset.insert", str(handle)))
                require(outcome["status"] == FAILED and outcome["task_id"] == outcome["created_id"] == 0
                    and wire.snapshot() == doc and host_view(wire) == after and host_station(wire) == before_station,
                    "Host consumer refusal changed resource/catalog/document/leases")
            require(wire.snapshot() == doc and host_view(wire) == after and host_station(wire) == before_station
                and host_asset_bytes(wire, handle) == content,
                "Host consumer support probe mutated document, ResourceRef, bytes or Station ownership")
            refs.append((rid, path, content))
            old_epoch = operation
        require(not retained_files(data), "Host registration/consumer rejection copied reference bytes to permanent versions")
        evidence["checks"].append("Host_v2_register_lost_reply_exact_token_replay_generic_delivery_and_independent_PNG_consumer_support")
        evidence["checks"].append("Host_v1_resource_probe_submit_rejected_without_side_effect_or_sequence_consumption")
        body = host_view(wire)["body"]
        _, final = invoke(console, "stop", data, "portable")
        require(final["state"] == "stopped", "registration Host did not stop")
        stopped = True
        stopped = False
        _, started = invoke(console, "start", data, "portable")
        require(started["state"] == "running", "registration Host did not cold restart")
        require(host_view(wire)["body"] == body and not host_station(wire)[1], "cold Host lost generic catalog or restored transient leases")
        rejected = host_apply(wire, old_epoch, WRONG_EPOCH)
        require(rejected["disposition"] == 3 and rejected["resource_id"] == 0 and host_view(wire)["body"] == body,
            "old Host incarnation registration created another resource")
        for rid, path, content in refs:
            host_acquire(wire, rid, content)
            require(path.read_bytes() == content, "Host cold delivery modified a source")
        evidence["checks"].append("Host_cold_restore_retains_generic_resource_IDs_and_read_only_bytes_without_restoring_Station")
    finally:
        if not stopped:
            _, final = invoke(console, "stop", data, "portable")
            require(final["state"] == "stopped", "owned registration Host cleanup failed")
            stopped = True
        evidence["host_stopped"] = stopped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("resource-registration"))
    args = parser.parse_args()
    require(os.name == "nt", "actual registration DLL/Host verification requires Windows")
    require(RESOURCE_API_VERSION == 2 and identity()["host_api"] >= 10, "registration fixture requires resource API v2 and ABI10")
    root = claim(args.root)
    portable = (OUTPUT / "portable").resolve()
    before = hashes(portable)
    evidence = {"format": "cutrans-resource-registration-verification/1", "root": str(root), "checks": [],
        "artifact_hashes": before, "passed": False, "limits": [
            "No GUI, drag/drop, IME, installer, system registration or release acceptance",
            "PNG relocate/adopt policy is unchanged; generic replacement/version adoption is a later contract",
            "Receipts are incarnation-local; unknown outcomes require the identical pending token",
            "Unused read-only source grants may survive failed catalog publication; all originals and links are retained"]}
    try:
        require(not (portable / "data").exists(), "tested portable artifact already contains runtime data")
        dll = c.WinDLL(str(portable / "runtime/cutrans_vm_runtime.dll"))
        configure(dll)
        require(dll.cutrans_vm_abi_version() == identity()["host_api"], "actual DLL ABI differs from product identity")
        native_types(dll, portable / "runtime", root, evidence)
        native_failures(dll, portable / "runtime", root, evidence)
        native_boundaries(dll, portable / "runtime", root, evidence)
        native_versions(dll, portable / "runtime", root, evidence)
        host_case(portable / "cutrans_vm.exe", root, evidence)
        require(hashes(portable) == before and not (portable / "data").exists(), "registration verification mutated tested artifacts/runtime data")
        evidence["passed"] = True
        print(f"CUTRANS_RESOURCE_REGISTRATION_VERIFY_OK checks={len(evidence['checks'])} evidence={root}")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        evidence["artifact_hashes_after"] = hashes(portable)
        (root / "report.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)


if __name__ == "__main__":
    main()
