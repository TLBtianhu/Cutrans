"""C2c1 real DLL/Host checks for cache-first registered resources and RAM detach.

No GUI or real user data. Strict fixed-version reads retain their own contract.
Only synthetic objects below a claimed root are moved; all originals survive.
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
from verify_assets import AssetListReport
from verify_edit_commit import exclusive_file
from verify_input import hashes
from verify_jobs import OK, ACCEPTED, FAILED, require, tiny_png
from verify_resource_operations import Native, configure, request, protected, resource_files
from verify_resource_versions import (
    COLOR_A,
    COLOR_B,
    assert_pin,
    assert_projection,
    import_source,
    source_read,
    retained_files,
    document_state,
    history_bytes,
    row,
    assert_output)

UNCHECKED, UNCHANGED, MISSING, CHANGED, IDENTITY_CHANGED, UNVERIFIED, UNAVAILABLE, SUPERSEDED = range(8)


def station_report(report):
    require(report.struct_size == c.sizeof(AssetListReport) and report.abi_version == identity()["host_api"]
        and report.reserved == 0 and report.count <= 16, "invalid actual Station report")
    result = {}
    for item in report.entries[:report.count]:
        require(item.handle > 0 and item.reserved == item.reserved2 == 0 and item.source_status in range(8),
            "invalid actual Station entry")
        result[item.handle] = {"library_id": item.library_id, "kind": item.library_kind,
            "hash": bytes(item.content_hash).hex(), "leases": item.leases, "size": item.byte_length,
            "source_status": item.source_status}
    return report.revision, result


def station(runtime):
    report = AssetListReport()
    require(runtime.library.cutrans_vm_asset_list(runtime.handle, c.byref(report)) == OK, "Station query failed")
    return station_report(report)


def ensure(runtime, resource_id, digest, expected=ACCEPTED):
    runtime.legacy("asset.ensure", f"{resource_id} {digest}", expected)
    matches = [handle for handle, item in station(runtime)[1].items()
               if item["library_id"] == resource_id and item["hash"] == digest]
    require(len(matches) == 1, "ensure did not preserve one exact registered resource generation")
    return matches[0]


def move_owned(source, target, evidence):
    source, target = check_root(source), check_root(target)
    require(not target.exists(), "case would overwrite retained evidence")
    source.rename(target)
    evidence.setdefault("preserved", []).append({"from": str(source), "to": str(target)})


def native_lifecycle(dll, resource, root, evidence):
    case = root / "lifecycle"
    case.mkdir()
    source = check_root(case / "original-name.png")
    a, b = tiny_png(COLOR_A), tiny_png(COLOR_B)
    digest = hashlib.sha256(a).hexdigest()
    source.write_bytes(a)
    data = case / "data"
    runtime = Native(dll, resource, data, evidence)
    try:
        handle = import_source(runtime, source)
        runtime.legacy("library.folder.create", "0 retained-parent")
        runtime.legacy("library.move", "1 2")
        before_view, before_work = runtime.view(), protected(runtime)
        auth = data / "session/external-sources.json"
        original_auth = auth.read_bytes()
        require(not retained_files(data), "import unexpectedly pinned the fixture before the RAM test")
        kernel, locked_source = exclusive_file(source)
        try:
            before = station(runtime)
            for _ in range(12):
                require(ensure(runtime, 1, digest) == handle, "RAM ensure changed handle")
            require(station(runtime) == before, "RAM hit grew lease count or republished Station")
            runtime.legacy("asset.check", str(handle))
            require(station(runtime)[1][handle]["source_status"] == UNAVAILABLE,
                "locked source check pretended to be missing or unchanged")
            assert_projection(runtime, handle, a)
        finally:
            kernel.CloseHandle(locked_source)
        evidence["checks"].append("locked_source_RAM_ensure_keeps_exact_handle_revision_and_lease_without_revalidation")

        # Same physical object, different bytes. Observation must not save hash
        # into authorization or change Catalog head. The auth lock proves that
        # check is not using the old noteRead persistence path.
        source.write_bytes(b)
        kernel, lock = exclusive_file(auth)
        try:
            runtime.legacy("asset.check", str(handle))
            require(station(runtime)[1][handle]["source_status"] == CHANGED,
                "pure observation failed while the authorization file was locked")
        finally:
            kernel.CloseHandle(lock)
        require(auth.read_bytes() == original_auth and runtime.view() == before_view and protected(runtime) == before_work,
            "source observation changed authorization, catalog, document or Station ownership")
        assert_projection(runtime, handle, a)
        source.write_bytes(a)
        runtime.legacy("asset.check", str(handle))
        require(station(runtime)[1][handle]["source_status"] == UNCHANGED, "same content check failed")
        evidence["checks"].append("inplace_changes_are_observations_only_and_do_not_write_auth_or_catalog")

        move_owned(source, case / "retired-original.png", evidence)
        before = station(runtime)
        ensure(runtime, 1, digest)
        require(station(runtime) == before, "missing original changed a cache-first hit")
        runtime.legacy("asset.check", str(handle))
        require(station(runtime)[1][handle]["source_status"] == MISSING, "missing source was not reported separately")
        assert_projection(runtime, handle, a)
        runtime.legacy("asset.open", "library://1", FAILED)
        source_read(runtime, "library://1", expected=13)
        require(not retained_files(data), "observation or ensure secretly persisted content")
        evidence["checks"].append("missing_source_preserves_complete_RAM_while_strict_current_reads_still_refuse")

        # Both failures occur after a legitimate RAM match. Preserve exact
        # blockers and originals rather than delete inferred garbage.
        block = check_root(data / "library/versions/1")
        block.parent.mkdir(parents=True, exist_ok=True)
        block.write_bytes(b"owned C2c1 version blocker")
        before = station(runtime)
        runtime.legacy("library.detach", "1", FAILED)
        require(runtime.view() == before_view and station(runtime) == before and block.read_bytes() == b"owned C2c1 version blocker",
            "failed version publication changed ownership or destroyed its blocker")
        move_owned(block, case / "retired-version-blocker", evidence)
        catalog = data / "library/catalog.json"
        kernel, lock = exclusive_file(catalog)
        try:
            runtime.legacy("library.detach", "1", FAILED)
            require(runtime.view() == before_view and station(runtime) == before, "failed catalog publication changed RAM or ownership")
        finally:
            kernel.CloseHandle(lock)
        assert_pin(data, digest, a)
        runtime.legacy("library.detach", "1")
        current = runtime.view()["body"]["resources"][0]
        require(current["id"] == 1 and current["parent_id"] == 2 and current["label"] == "original-name.png" and current["kind"] == "owned"
            and current["provenance"] == "detached" and current["sha256"] == digest
            and current["source"] == before_view["body"]["resources"][0]["source"],
            "RAM independent save changed identity, display name, original provenance or bytes")
        require(station(runtime)[1][handle]["source_status"] == UNCHECKED, "old external missing state survived the binding change")
        runtime.legacy("asset.check", str(handle))
        require(station(runtime)[1][handle]["source_status"] == UNCHANGED, "owned version check failed")
        assert_projection(runtime, handle, a)
        require(auth.read_bytes() == original_auth, "RAM detach touched the original authorization record")
        evidence["checks"].append("RAM_independent_save_is_failure_safe_keeps_id_label_parent_and_provenance_and_invalidates_old_observation")
    finally:
        runtime.close()
    runtime = Native(dll, resource, data, evidence)
    try:
        require(not station(runtime)[1], "cold restore rebuilt live Station objects")
        ensure(runtime, 1, digest)
        require(source_read(runtime, "library://1") == a, "independent content could not cold restore without original")
        evidence["checks"].append("cold_restore_reads_owned_content_without_original_and_does_not_restore_RAM")
    finally:
        runtime.close()


def versions_and_identity(dll, resource, root, evidence):
    case = root / "versions"
    case.mkdir()
    a, b = tiny_png(COLOR_A), tiny_png(COLOR_B)
    ha, hb = hashlib.sha256(a).hexdigest(), hashlib.sha256(b).hexdigest()
    source_a, source_b, equal_a = [case / name for name in ("A.png", "B.png", "equal-A.png")]
    source_a.write_bytes(a)
    source_b.write_bytes(b)
    equal_a.write_bytes(a)
    runtime = Native(dll, resource, case / "data", evidence)
    try:
        handle_a = import_source(runtime, source_a)
        handle_equal = import_source(runtime, equal_a)
        require(handle_equal != handle_a and ensure(runtime, 2, ha) == handle_equal and ensure(runtime, 1, ha) == handle_a,
            "equal bytes merged different resource identities")
        runtime.submit_edit("editor.asset.insert", str(handle_a))
        old_job = runtime.submit_edit("editor.export.png", "session://exports/old-A.png", ACCEPTED).task_id
        before_doc, old_history = document_state(runtime), history_bytes(runtime.data)
        runtime.legacy("asset.check", str(handle_a))
        runtime.apply(request(runtime.probe(source_b), source_b))
        require(station(runtime)[1][handle_a]["source_status"] == UNCHECKED, "adopt retained an observation for another binding")
        before_view, before_station = runtime.view(), station(runtime)
        temporarily_missing = case / "temporarily-missing-B.png"
        move_owned(source_b, temporarily_missing, evidence)
        runtime.legacy("library.detach", "1", FAILED)
        require(runtime.view() == before_view and station(runtime) == before_station,
            "detach used resident old A to roll back the missing current B head")
        move_owned(temporarily_missing, source_b, evidence)
        handle_b = ensure(runtime, 1, hb)
        require(handle_b != handle_a, "current head ensure selected a different resident version")
        assert_projection(runtime, handle_a, a)
        assert_projection(runtime, handle_b, b)
        before = station(runtime)
        rejected = runtime.legacy_status("asset.ensure", f"1 {ha}")
        require(rejected not in (OK, ACCEPTED) and station(runtime) == before, "stale expected head acquired or changed Station")
        kernel, lock = exclusive_file(source_b)
        try:
            runtime.legacy("asset.check", str(handle_a))
        finally:
            kernel.CloseHandle(lock)
        require(station(runtime)[1][handle_a]["source_status"] == SUPERSEDED, "old resident version was checked as the new source")
        require(document_state(runtime) == before_doc and history_bytes(runtime.data) == old_history,
            "current-resource loading or observation rebased existing work")
        runtime.drain()
        assert_output(row(runtime, old_job), runtime.data / "exports/old-A.png", COLOR_A)
        before = station(runtime)
        rejected = runtime.legacy_status("asset.check", "999999")
        require(rejected not in (OK, ACCEPTED) and station(runtime) == before, "unloaded check created an object")
        evidence["checks"].append("current_head_selection_is_exact_and_keeps_old_Station_document_and_queued_job_versions")
        evidence["checks"].append("different_resources_do_not_merge_and_unloaded_or_stale_requests_have_no_effect")
    finally:
        runtime.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("resident-resources"))
    args = parser.parse_args()
    require(os.name == "nt", "actual DLL/Host verification requires Windows")
    root = claim(args.root)
    portable = (OUTPUT / "portable").resolve()
    before = hashes(portable)
    evidence = {"format": "cutrans-resident-resources-verification/1", "root": str(root), "checks": [],
        "artifact_hashes": before, "passed": False, "limits": ["Current full encoded PNG Station objects only; no LRU",
        "Source check is synchronous and observational, not global F5 or automatic new-generation adoption",
        "No real GUI/IME, installer, cloud, filesystem sandbox or release acceptance"]}
    try:
        dll = c.WinDLL(str(portable / "runtime/cutrans_vm_runtime.dll"))
        configure(dll)
        require(dll.cutrans_vm_abi_version() == identity()["host_api"] >= 10, "wrong actual Station ABI")
        native_lifecycle(dll, portable / "runtime", root, evidence)
        versions_and_identity(dll, portable / "runtime", root, evidence)
        require(hashes(portable) == before and not (portable / "data").exists(), "verification changed artifact or default data")
        evidence["passed"] = True
        print(f"CUTRANS_RESIDENT_RESOURCES_VERIFY_OK checks={len(evidence['checks'])} evidence={root}")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        evidence["artifact_hashes_after"] = hashes(portable)
        (root / "report.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)


if __name__ == "__main__":
    main()
