"""C1 real-artifact verification of adopted library versions; no GUI or real data.

Every fixture lives below one claimed verification root. Current browsing and
hash-bound reads have different purposes: retaining an adopted revision must
not silently detach an external reference or conceal drift in current browsing.
All subprocesses go through the quiet automation_process wrapper.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import struct
import sys
import threading
import time
from pathlib import Path

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from product import identity
from verification_paths import check_root, claim, default_root, remove, retain
from verify_assets import (AssetInfo, AssetListReport, LibraryListReport,
                           asset_projection, library_projection)
from environment_harness import run
from verify_input import ByteSlice, hashes, string_slice
from verify_jobs import ACCEPTED, FAILED, OK, SMALL, digest_text, png, require, sha256, tiny_png
from verify_jobs_async import AsyncNative, configure as jobs_configure
from verify_workspace import request, stamp

INVALID_ARGUMENTS = 3
COLOR_A, COLOR_B, COLOR_C = (12, 34, 56, 255), (90, 110, 130, 255), (180, 20, 70, 255)


def configure(library):
    jobs_configure(library)
    declarations = {
        "cutrans_vm_asset_open_external": ([ctypes.c_void_p, ByteSlice, ctypes.POINTER(ctypes.c_uint64)], ctypes.c_int32),
        "cutrans_vm_source_read": ([ctypes.c_void_p, ByteSlice, ByteSlice, ctypes.c_void_p, ctypes.c_size_t,
                                    ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int32),
        "cutrans_vm_asset_list": ([ctypes.c_void_p, ctypes.POINTER(AssetListReport)], ctypes.c_int32),
        "cutrans_vm_asset_preview": ([ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(AssetInfo)], ctypes.c_int32),
        "cutrans_vm_library_list": ([ctypes.c_void_p, ctypes.POINTER(LibraryListReport)], ctypes.c_int32),
        "cutrans_vm_library_label": ([ctypes.c_void_p, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int32),
    }
    for name in ("cutrans_vm_asset_source", "cutrans_vm_asset_read"):
        declarations[name] = ([ctypes.c_void_p, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int32)
    for name, (arguments, result) in declarations.items():
        function = getattr(library, name)
        function.argtypes, function.restype = arguments, result


def listing(runtime):
    report = AssetListReport()
    require(runtime.library.cutrans_vm_asset_list(runtime.handle, ctypes.byref(report)) == OK
            and report.struct_size == ctypes.sizeof(AssetListReport) and report.reserved == 0
            and report.count <= 16, "invalid Station projection")
    return {entry.handle: {"leases": entry.leases, "library_id": entry.library_id,
                          "library_kind": entry.library_kind, "byte_length": entry.byte_length}
            for entry in report.entries[:report.count]}


def import_source(runtime, source):
    value, storage = string_slice(str(source))
    handle = ctypes.c_uint64(999)
    status = runtime.library.cutrans_vm_asset_open_external(runtime.handle, value, ctypes.byref(handle))
    require(status == ACCEPTED and handle.value > 0, f"owned synthetic Source import failed: {status}")
    return handle.value


def source_read(runtime, uri, digest=None, expected=OK):
    uri_value, uri_storage = string_slice(uri)
    hash_value, hash_storage = string_slice(digest) if digest is not None else (ByteSlice(), None)
    before, required = listing(runtime), ctypes.c_size_t(999)
    function = runtime.library.cutrans_vm_source_read
    status = function(runtime.handle, uri_value, hash_value, None, 0, ctypes.byref(required))
    if expected != OK:
        require(status == expected and required.value == 0, f"source query failure={status}, length={required.value}")
        sentinel = ctypes.create_string_buffer(b"\xa5" * 128, 128)
        old = sentinel.raw
        required.value = 999
        status = function(runtime.handle, uri_value, hash_value, sentinel, len(sentinel), ctypes.byref(required))
        require(status == expected and required.value == 0 and sentinel.raw == old,
                "failed source read wrote bytes or returned a misleading length")
        require(listing(runtime) == before, "failed Source copy changed Station ownership")
        return None
    require(status == SMALL and 0 < required.value <= 16 * 1024 * 1024, "Source length query failed or exceeded its encoded budget")
    length = required.value
    short = ctypes.create_string_buffer(b"\xa5" * (length - 1), length - 1)
    old = short.raw
    status = function(runtime.handle, uri_value, hash_value, short, len(short), ctypes.byref(required))
    require(status == SMALL and required.value == length and short.raw == old, "short Source buffer was overwritten")
    output = ctypes.create_string_buffer(length)
    status = function(runtime.handle, uri_value, hash_value, output, len(output), ctypes.byref(required))
    require(status == OK and required.value == length, "Source copy failed or changed its bound length")
    content = output.raw[:required.value]
    if digest is not None:
        require(hashlib.sha256(content).hexdigest() == digest, "Source copy used a different content version")
    require(listing(runtime) == before, "Source copy created, acquired or released a Station lease")
    return content


def pin_path(data, digest, library_id=1):
    return check_root(data / "library/versions" / str(library_id) / f"{digest}.bin")


def retained_files(data):
    base = check_root(data / "library/versions")
    return {path.relative_to(base).as_posix(): sha256(path) for path in sorted(base.rglob("*")) if path.is_file()} if base.exists() else {}


def assert_pin(data, digest, content, library_id=1):
    path = pin_path(data, digest, library_id)
    require(path.is_file() and path.read_bytes() == content and sha256(path) == digest,
            "retained adopted version is absent or is not the exact accepted encoded bytes")
    return str(path)


def assert_reference(runtime, expected_hash):
    report, _ = library_projection(runtime.library, runtime.handle, 1)
    item = report.entries[0]
    require(item.id == 1 and item.kind == 1 and item.provenance == 0 and bytes(item.content_hash).hex() == expected_hash,
            "version retention changed stable library identity, reference ownership or current head")
    require(not (runtime.data / "library/content/1.bin").exists(), "retaining a revision silently detached the reference")


def history_bytes(data):
    path = data / "documents/history.txt"
    return path.read_bytes() if path.is_file() else None


def document_state(runtime):
    info, text = runtime.snapshot()
    return {"stamp": stamp(info.stamp), "fingerprint": info.fingerprint,
            "high_water": info.node_id_high_water, "flags": info.flags, "text": text.decode("utf-8")}


def assert_projection(runtime, handle, content, library_id=1):
    info, actual, uri = asset_projection(runtime.library, runtime.handle, handle)
    require(actual == content and uri == f"library://{library_id}" and bytes(info.content_hash).hex() == hashlib.sha256(content).hexdigest(),
            "exact acquired Station handle describes the wrong content version")


def preview(runtime, expected=ACCEPTED):
    # playback.start performs a real shared-render Source acquisition and frame
    # evaluation. Pixel assertions below use the exported PNG, not a fake GUI.
    runtime.legacy("playback.start", "1", expected)
    if expected == ACCEPTED:
        runtime.legacy("playback.stop")


def row(runtime, identity):
    return next(item for item in runtime.all_jobs() if item["id"] == identity)


def assert_output(item, path, pixel):
    output = png(path, 1, 1)
    require(output["first_pixel"] == list(pixel), "export used a different Source revision")
    require(item["state"] == item["phase"] == "succeeded" and not item["persistence_pending"]
            and digest_text(item["output_sha256"]) == output["sha256"] and item["output_size"] == output["size"],
            "export bytes and durable outcome disagree")
    return output


def export(runtime, filename, pixel):
    identity = runtime.submit_edit("editor.export.png", f"session://exports/{filename}", ACCEPTED).task_id
    runtime.drain()
    item = row(runtime, identity)
    return {"job": item, "output": assert_output(item, runtime.data / "exports" / filename, pixel)}


def admission_and_cold_read_case(library, resource, root, evidence):
    data, source = root / "adopted version data", check_root(root / "adopted-reference.png")
    content, changed = tiny_png(COLOR_A), tiny_png(COLOR_B)
    source.write_bytes(content)
    digest = hashlib.sha256(content).hexdigest()
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        handle = import_source(runtime, source)
        assert_projection(runtime, handle, content)
        assert_reference(runtime, digest)
        require(source_read(runtime, "library://1", digest) == content, "exact Source read returned different bytes")
        require(source_read(runtime, "library://1") == content, "legacy current Source read returned different bytes")
        require(listing(runtime)[handle]["leases"] == 1 and not retained_files(data),
                "browse/Source copy persisted a content version or changed the original lease")
        evidence["checks"].append("reference_import_browse_and_bounded_Source_copy_do_not_retain_detach_or_change_Station")

        before, old_history = document_state(runtime), history_bytes(data)
        blocker = check_root(data / "library/versions/1")
        blocker.parent.mkdir(parents=True, exist_ok=True)
        require(not blocker.exists(), "pin failure fixture would overwrite existing evidence")
        sentinel = b"owned C1 retention parent blocker"
        blocker.write_bytes(sentinel)
        runtime.submit_edit("editor.asset.insert", str(handle), FAILED)
        require(document_state(runtime) == before and history_bytes(data) == old_history and blocker.read_bytes() == sentinel,
                "failed retention published a document/history change or modified its blocker")
        blocker.unlink()  # Exact file this case created, not an inferred garbage directory.
        evidence["deleted"].append({"path": str(blocker), "reason": "removed this case's explicit retention blocker"})
        runtime.submit_edit("editor.asset.insert", str(handle))
        assert_pin(data, digest, content)
        assert_reference(runtime, digest)
        runtime.legacy("doc.save", "session://saved-document.cut")
        require(digest in document_state(runtime)["text"], "insert did not bind the content version")
        evidence["checks"].append("retention_failure_keeps_document_revision_history_and_blocker_unchanged")
    finally:
        runtime.close()

    cold = []
    for state in ("changed", "deleted"):
        if state == "changed":
            source.write_bytes(changed)  # Existing file: preserve OS identity, change only content.
        else:
            source.unlink()
            evidence["deleted"].append({"path": str(source), "reason": "deleted this case's synthetic external Source"})
        runtime = AsyncNative(library, resource, data, evidence)
        try:
            require(not listing(runtime), "restart reconstructed Station as a second persistent source")
            runtime.legacy("asset.open", "library://1", FAILED)
            require(source_read(runtime, "library://1", digest) == content and not listing(runtime),
                    "cold exact Source copy returned other bytes or revived Station")
            preview(runtime)
            output = export(runtime, f"cold-{state}.png", COLOR_A)
            assert_reference(runtime, digest)
            assert_pin(data, digest, content)
            cold.append({"external_state": state, "export": output})
        finally:
            runtime.close()
    evidence["cold_adopted_reads"] = cold
    evidence["checks"].append("saved_version_survives_restart_external_drift_and_deletion_while_current_browse_reports_failure")


def refresh_jobs_and_history_case(library, resource, root, evidence):
    data, source = root / "coexisting versions data", check_root(root / "coexisting-reference.png")
    a, b, c = tiny_png(COLOR_A), tiny_png(COLOR_B), tiny_png(COLOR_C)
    ha, hb, hc = (hashlib.sha256(content).hexdigest() for content in (a, b, c))
    source.write_bytes(a)
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        handle_a = import_source(runtime, source)
        runtime.submit_edit("editor.asset.insert", str(handle_a))
        first = document_state(runtime)
        job_a = runtime.submit_edit("editor.export.png", "session://exports/queued-A.png", ACCEPTED).task_id
        source.write_bytes(b)
        runtime.legacy("library.refresh", "1")
        require(document_state(runtime) == first, "refresh implicitly adopted its new head into the old document")
        runtime.legacy("asset.open", "library://1", ACCEPTED)
        handles = listing(runtime)
        handle_b = next(handle for handle in handles if handle != handle_a)
        assert_projection(runtime, handle_a, a)
        assert_projection(runtime, handle_b, b)
        for expected_handle, digest, content in ((handle_a, ha, a), (handle_b, hb, b)):
            before = listing(runtime)
            require(source_read(runtime, "library://1", digest) == content, "exact Source copy selected the other URI version")
            assert_projection(runtime, expected_handle, content)
            require(listing(runtime) == before, "exact Source copy changed another owner's lease")
        before = listing(runtime)
        source_read(runtime, "library://1", "not-a-sha256", INVALID_ARGUMENTS)
        source_read(runtime, "library://1", "f" * 64, FAILED)
        require(listing(runtime) == before, "invalid or missing-version Source copy changed Station")
        preview(runtime)
        runtime.submit_edit("editor.asset.insert", str(handle_b))
        second = document_state(runtime)
        require(ha in first["text"] and hb in second["text"] and first["fingerprint"] != second["fingerprint"],
                "explicit insertion did not create an independently versioned document")
        assert_pin(data, ha, a)
        assert_pin(data, hb, b)
        job_b = runtime.submit_edit("editor.export.png", "session://exports/queued-B.png", ACCEPTED).task_id
        source.write_bytes(c)
        runtime.legacy("library.refresh", "1")
        assert_reference(runtime, hc)
        require(hc not in retained_files(data) and not pin_path(data, hc).exists(), "refresh retained an unadopted head")
        runtime.drain()
        outputs = {"A": assert_output(row(runtime, job_a), data / "exports/queued-A.png", COLOR_A),
                   "B": assert_output(row(runtime, job_b), data / "exports/queued-B.png", COLOR_B)}
        require(row(runtime, job_a)["source_fingerprint"] == first["fingerprint"]
                and row(runtime, job_b)["source_fingerprint"] == second["fingerprint"], "queued Job changed its original document version")
        evidence["queued_versions"] = {"first": row(runtime, job_a), "second": row(runtime, job_b), "outputs": outputs}
        evidence["checks"].append("two_queued_versions_keep_independent_pixels_after_current_library_refreshes_again")
        runtime.submit_edit("history.undo")
        require(ha in document_state(runtime)["text"], "undo did not restore the old Source declaration")
        preview(runtime)
        old_output = export(runtime, "undo-A.png", COLOR_A)
        runtime.submit_edit("history.redo")
        require(hb in document_state(runtime)["text"], "redo did not restore the newer Source declaration")
        preview(runtime)
        new_output = export(runtime, "redo-B.png", COLOR_B)
        assert_projection(runtime, handle_a, a)
        assert_projection(runtime, handle_b, b)
        assert_reference(runtime, hc)
        evidence["history_versions"] = {"undo": old_output, "redo": new_output, "station": listing(runtime)}
        evidence["checks"].append("refresh_keeps_old_new_Station_versions_no_lease_Source_copies_and_undo_redo_rendering")
        interrupted = runtime.submit_edit("editor.export.png", "session://exports/interrupted-B.png", ACCEPTED).task_id
    finally:
        runtime.close()

    runtime = AsyncNative(library, resource, data, evidence)
    try:
        parent = row(runtime, interrupted)
        require(parent["state"] == "interrupted", "unfinished attempt was not explained on recreation")
        preview(runtime)
        current = runtime.snapshot()[0]
        token = request(1, current.stamp, "task.retry", f"{interrupted} session://exports/retried-B.png", client=(0xC101, 0xC102))
        accepted, replay = runtime.exact_submit(token, ACCEPTED, 1), runtime.exact_submit(token, ACCEPTED, 2)
        require(accepted.task_id == replay.task_id, "retry duplicate token allocated another identity")
        runtime.drain()
        child = row(runtime, accepted.task_id)
        require(child["attempt"] == 2 and child["retry_of"] == interrupted and child["origin"] == parent["origin"]
                and child["source_fingerprint"] == parent["source_fingerprint"], "retry changed accepted version/lineage")
        output = assert_output(child, data / "exports/retried-B.png", COLOR_B)
        evidence["retry_version"] = {"parent": parent, "child": child, "output": output}
        evidence["checks"].append("interrupted_retry_after_restart_reads_retained_original_and_exact_token_is_idempotent")
        pins_before = retained_files(data)
    finally:
        runtime.close()

    # Only these explicit, claimed cache/temp directories are removed. Version
    # bytes are durable Sources and never members of this cleanup whitelist.
    for relative in ("cache", "temp"):
        directory = check_root(data / relative)
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "c1-owned-sentinel.txt").write_text("rebuildable owned fixture", encoding="utf-8")
        files = [str(path) for path in directory.rglob("*") if path.is_file()]
        remove(directory)
        evidence["deleted"].append({"path": str(directory), "files": files, "reason": "claimed cache/temp cleanup proof"})
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        require(retained_files(data) == pins_before, "cache/temp cleanup changed durable version content")
        preview(runtime)
        evidence["after_cache_cleanup"] = export(runtime, "after-cache-B.png", COLOR_B)
        require(row(runtime, accepted.task_id) == child, "restart/cache cleanup changed an existing terminal attempt")
        evidence["checks"].append("deleting_only_claimed_cache_temp_does_not_damage_adopted_bytes_or_history_jobs")
    finally:
        runtime.close()


def corrupt_version_case(library, resource, root, evidence):
    data, source = root / "corrupt adopted version data", check_root(root / "corrupt-reference.png")
    content = tiny_png(COLOR_A)
    digest = hashlib.sha256(content).hexdigest()
    source.write_bytes(content)
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        handle = import_source(runtime, source)
        runtime.submit_edit("editor.asset.insert", str(handle))
        path = pin_path(data, digest)
        require(path.read_bytes() == content, "corruption fixture did not start from retained bytes")
        damaged = b"owned C1 deliberate retained-version corruption"
        path.write_bytes(damaged)
        before, old_history = document_state(runtime), history_bytes(data)
        source_read(runtime, "library://1", digest, FAILED)
        runtime.submit_edit("editor.asset.insert", str(handle), FAILED)
        require(document_state(runtime) == before and history_bytes(data) == old_history and path.read_bytes() == damaged,
                "same-version reinsertion silently healed corruption or changed document/history")
        preview(runtime, FAILED)
        target = check_root(data / "exports/protected.png")
        target.parent.mkdir(parents=True, exist_ok=True)
        sentinel = b"owned C1 output sentinel: rejected corruption must not replace"
        target.write_bytes(sentinel)
        runtime.submit_edit("editor.export.png", "session://exports/protected.png", FAILED)
        require(not runtime.all_jobs() and target.read_bytes() == sentinel and path.read_bytes() == damaged,
                "corrupt retained data fell back to current bytes, published a Task or touched output")
        evidence["corrupt_retained"] = {"path": str(path), "damaged_sha256": sha256(path), "protected_output": str(target)}
        evidence["checks"].append("retained_corruption_fails_closed_without_live_fallback_reinsert_healing_or_output_replacement")
    finally:
        runtime.close()


def legacy_fallback_and_job_pin_case(library, resource, root, evidence):
    data, source = root / "legacy unpinned version data", check_root(root / "legacy-reference.png")
    a, b = tiny_png(COLOR_A), tiny_png(COLOR_B)
    digest = hashlib.sha256(a).hexdigest()
    source.write_bytes(a)
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        import_source(runtime, source)
        fixture = check_root(data / "legacy-unpinned.cut")
        fixture.write_text("version=3\nresolution=1x1\nfps=30\nnodes:\n"
                           f'c0=image{{ path:"library://1",sha256:"{digest}" }}\noutput=c0\n', encoding="utf-8")
        runtime.submit_edit("doc.open", "session://legacy-unpinned.cut")
        preview(runtime)
        require(not retained_files(data), "compatible missing-version read silently pinned an unadopted revision")
        source.write_bytes(b)
        source_read(runtime, "library://1", digest, FAILED)
        preview(runtime, FAILED)
        require(not retained_files(data), "drifted missing-version fallback retained different bytes")
        source.write_bytes(a)
        blocker = check_root(data / "library/versions/1")
        blocker.parent.mkdir(parents=True, exist_ok=True)
        blocker.write_bytes(b"owned C1 job admission retention blocker")
        before, old_history = document_state(runtime), history_bytes(data)
        runtime.submit_edit("editor.export.png", "session://exports/legacy-job.png", FAILED)
        require(not runtime.all_jobs() and document_state(runtime) == before and history_bytes(data) == old_history,
                "failed pre-admission pin published a task or edited the document")
        blocker.unlink()
        evidence["deleted"].append({"path": str(blocker), "reason": "removed this case's Job pin admission blocker"})
        accepted = runtime.submit_edit("editor.export.png", "session://exports/legacy-job.png", ACCEPTED).task_id
        assert_pin(data, digest, a)
        require(accepted == 1, "failed Job pin consumed a task identity")
        source.write_bytes(b)
        runtime.legacy("library.refresh", "1")
        runtime.drain()
        output = assert_output(row(runtime, accepted), data / "exports/legacy-job.png", COLOR_A)
        evidence["legacy_fallback_job_pin"] = {"job": row(runtime, accepted), "output": output}
        evidence["checks"].append("legacy_same_hash_fallback_rejects_drift_and_Job_pins_before_acceptance_without_publishing_on_failure")
    finally:
        runtime.close()


def junction_boundary_case(library, resource, root, evidence):
    data = root / "junction boundary data"
    source = check_root(root / "junction-reference.png")
    content = tiny_png(COLOR_A)
    digest = hashlib.sha256(content).hexdigest()
    source.write_bytes(content)
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        handle = import_source(runtime, source)
        # Both ends are explicit new paths in this claimed case. This is not an
        # installed program directory, a real cache or an inferred cleanup item.
        link = check_root(data / "library/versions")
        target = check_root(root / "synthetic program cache")
        require(not link.exists() and not target.exists(), "junction fixture would reuse an existing path")
        (target / "1").mkdir(parents=True)
        (target / "1" / f"{digest}.bin").write_bytes(content)
        (target / "owned-fixture.txt").write_text("synthetic program/cache boundary sentinel", encoding="utf-8")
        before_target = hashes(target)
        system_directory = ctypes.create_unicode_buffer(32768)
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.GetSystemDirectoryW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32]
        kernel.GetSystemDirectoryW.restype = ctypes.c_uint32
        length = kernel.GetSystemDirectoryW(system_directory, len(system_directory))
        require(0 < length < len(system_directory), "could not locate the system cmd.exe")
        cmd = Path(system_directory.value) / "cmd.exe"
        require(cmd.is_file(), "system cmd.exe is unavailable")
        run([str(cmd), "/d", "/c", "mklink", "/J", str(link), str(target)])
        require(getattr(link.lstat(), "st_file_attributes", 0) & 0x400 and link.resolve() == target.resolve(),
                "NTFS junction fixture did not point to its precise owned target")
        before, old_history = document_state(runtime), history_bytes(data)
        runtime.submit_edit("editor.asset.insert", str(handle), FAILED)
        source_read(runtime, "library://1", digest, FAILED)
        require(document_state(runtime) == before and history_bytes(data) == old_history and hashes(target) == before_target,
                "version retention/read followed a junction or changed document/history/target files")
        require(not runtime.all_jobs(), "junction rejection published an orphan task")
        evidence["junction_boundary"] = {"link": str(link), "target": str(target), "target_files": before_target,
            "actual_link_target": os.readlink(link), "retained_for_review": True}
        evidence["checks"].append("real_NTFS_versions_junction_is_rejected_for_adoption_and_reads_without_touching_owned_target")
        # Retain the junction and its target as evidence. No recursive deletion
        # follows it; no other product or system path is inspected or modified.
    finally:
        runtime.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("resource-versions"))
    args = parser.parse_args()
    require(os.name == "nt", "real library version DLL/Host verification requires Windows")
    root = claim(args.root)
    portable = (OUTPUT / "portable").resolve()
    resource, before = portable / "runtime", hashes(portable)
    evidence = {"format": "cutrans-resource-versions-verification/1", "root": str(root), "artifact_hashes": before,
        "checks": [], "deleted": [], "passed": False,
        "limits": ["C1 adopts durable encoded library versions; it does not provide relocate/adopt commands or a general FrameLease",
                   "Headless playback.start verifies shared render evaluation; exported 1x1 PNG validates pixels, not a GUI texture",
                   "Retention has no automatic garbage collection; all evidence and unowned/ambiguous data are retained",
                   "No GUI, system registration, installer or release verification is performed"]}
    try:
        library = ctypes.WinDLL(str(resource / "cutrans_vm_runtime.dll"))
        configure(library)
        require(library.cutrans_vm_abi_version() == identity()["host_api"], "Runtime ABI differs from product identity")
        admission_and_cold_read_case(library, resource, root, evidence)
        refresh_jobs_and_history_case(library, resource, root, evidence)
        corrupt_version_case(library, resource, root, evidence)
        legacy_fallback_and_job_pin_case(library, resource, root, evidence)
        junction_boundary_case(library, resource, root, evidence)
        require(hashes(portable) == before and not (portable / "data").exists(), "verification changed the tested artifact")
        evidence["passed"] = True
        print(f"CUTRANS_RESOURCE_VERSIONS_VERIFY_OK checks={len(evidence['checks'])} evidence={root}")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        evidence["artifact_hashes_after"] = hashes(portable)
        (root / "report.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)


if __name__ == "__main__":
    main()
