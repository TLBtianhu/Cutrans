"""C2b resource CAS/proof/receipts on the actual DLL and isolated Host.

Only owned synthetic data is changed. No GUI, installation or system registration.
Every replaced synthetic file and failed-attempt report is retained as evidence.
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
from concurrent.futures import ThreadPoolExecutor

sys.dont_write_bytecode = True
from build_paths import OUTPUT
from product import identity
from verification_paths import check_root, claim, default_root, retain
from verify_edit_commit import exclusive_file
from verify_input import ByteSlice, hashes, string_slice
from verify_jobs import ACCEPTED, FAILED, OK, SMALL, require, tiny_png
from verify_jobs_async import AsyncNative
from verify_resource_versions import (
    COLOR_A,
    COLOR_B,
    COLOR_C,
    assert_output,
    assert_pin,
    assert_projection,
    configure as versions_configure,
    document_state,
    history_bytes,
    import_source,
    listing,
    retained_files,
    row,
    source_read)
from verify_workspace import Stamp, stamp

STALE, WRONG_EPOCH, CONFLICT, EXPIRED, BAD_SEQUENCE, CANDIDATE_CHANGED, WRONG_KIND, MISMATCH = 64, 65, 66, 67, 68, 70, 71, 72
RELOCATE, ADOPT = 1, 2
RESOURCE_API_VERSION = 4
# Upper bound for one snapshot text; formerly the Host pipe's payload limit.
MAX_PAYLOAD = 17 * 1024 * 1024


class Proof(c.Structure):
    _fields_ = [("struct_size", c.c_uint32), ("api_version", c.c_uint32), ("stamp", Stamp),
        ("target_id", c.c_uint64), ("mode", c.c_uint32), ("reserved", c.c_uint32),
        ("head_hash", c.c_ubyte * 32), ("content_hash", c.c_ubyte * 32), ("path_hash", c.c_ubyte * 32),
        ("byte_length", c.c_uint64), ("volume_serial", c.c_uint64), ("file_index", c.c_uint64)]


class ProbeRequest(c.Structure):
    _fields_ = [("struct_size", c.c_uint32), ("api_version", c.c_uint32), ("expected", Stamp),
        ("target_id", c.c_uint64), ("mode", c.c_uint32), ("reserved", c.c_uint32), ("path", ByteSlice)]


class Request(c.Structure):
    _fields_ = [("struct_size", c.c_uint32), ("api_version", c.c_uint32),
        ("client_hi", c.c_uint64), ("client_lo", c.c_uint64), ("sequence", c.c_uint64),
        ("proof", Proof), ("path", ByteSlice)]


class Outcome(c.Structure):
    _fields_ = [("struct_size", c.c_uint32), ("api_version", c.c_uint32), ("status", c.c_int32),
        ("disposition", c.c_uint32), ("sequence", c.c_uint64), ("stamp", Stamp), ("resource_id", c.c_uint64)]


class Snapshot(c.Structure):
    _fields_ = [("struct_size", c.c_uint32), ("api_version", c.c_uint32), ("stamp", Stamp), ("text_len", c.c_size_t)]


SnapshotFn = c.CFUNCTYPE(c.c_int32, c.c_void_p, c.POINTER(Stamp), c.POINTER(Snapshot), c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t))
ProbeFn = c.CFUNCTYPE(c.c_int32, c.c_void_p, c.POINTER(ProbeRequest), c.POINTER(Proof))
SubmitFn = c.CFUNCTYPE(c.c_int32, c.c_void_p, c.POINTER(Request), c.POINTER(Outcome))


class Api(c.Structure):
    _fields_ = [("struct_size", c.c_uint32), ("api_version", c.c_uint32), ("context", c.c_void_p),
        ("snapshot", SnapshotFn), ("probe", ProbeFn), ("submit", SubmitFn),
        ("work_snapshot", c.c_void_p), ("work_submit", c.c_void_p),
        ("source_browse", c.c_void_p), ("source_read", c.c_void_p)]


def request(proof, path, seq=1, client=(0xC2B1, 0xC2B2)):
    value, storage = string_slice(str(path))
    result = Request(c.sizeof(Request), RESOURCE_API_VERSION, *client, seq, proof, value)
    result._storage = storage
    return result


def known(value):
    return {"status": value.status, "disposition": value.disposition, "sequence": value.sequence,
        "stamp": stamp(value.stamp), "resource_id": value.resource_id}


def configure(dll):
    versions_configure(dll)
    dll.cutrans_vm_resource_api.argtypes, dll.cutrans_vm_resource_api.restype = [c.c_void_p, c.POINTER(Api)], c.c_int32


class Native(AsyncNative):
    def __init__(self, dll, resource, data, evidence):
        super().__init__(dll, resource, data, evidence)
        self.resources = Api()
        result = dll.cutrans_vm_resource_api(self.handle, c.byref(self.resources))
        require(result == OK and self.resources.struct_size == c.sizeof(Api) and self.resources.api_version == RESOURCE_API_VERSION
            and self.resources.context == self.handle.value, "actual Runtime did not expose resource API v4")

    def raw_resources(self, expected=None, buffer=None):
        info, length = Snapshot(), c.c_size_t(999)
        result = self.resources.snapshot(self.handle, c.byref(expected) if expected is not None else None,
            c.byref(info), buffer, len(buffer) if buffer is not None else 0, c.byref(length))
        require(info.struct_size == c.sizeof(Snapshot) and info.api_version == RESOURCE_API_VERSION, "bad resource snapshot metadata")
        return result, info, length.value

    def view(self):
        result, first, length = self.raw_resources()
        require(result == SMALL and 0 < length == first.text_len < MAX_PAYLOAD, "bad resource snapshot length query")
        output = c.create_string_buffer(length)
        result, second, written = self.raw_resources(first.stamp, output)
        require(result == OK and written == length == second.text_len and stamp(first.stamp) == stamp(second.stamp),
            "resource snapshot combined different versions")
        body = json.loads(output.raw[:written])
        require(body["format"] == "cutrans-resource-snapshot/1", "wrong resource snapshot format")
        return {"stamp": stamp(second.stamp), "body": body}

    def probe(self, path, mode=ADOPT, target=1, expected=None, status=OK):
        expected = expected or Stamp(*self.view()["stamp"])
        value, storage = string_slice(str(path))
        query = ProbeRequest(c.sizeof(ProbeRequest), RESOURCE_API_VERSION, expected, target, mode, 0, value)
        proof = Proof()
        actual = self.resources.probe(self.handle, c.byref(query), c.byref(proof))
        require(actual == status, f"resource probe status={actual}, expected={status}")
        if status == OK:
            require(proof.struct_size == c.sizeof(Proof) and proof.api_version == RESOURCE_API_VERSION and proof.reserved == 0
                and stamp(proof.stamp) == stamp(expected) and proof.target_id == target and proof.mode == mode,
                "probe returned inconsistent proof")
            return proof
        return None

    def apply(self, value, status=OK, disposition=None):
        result = Outcome()
        transport = self.resources.submit(self.handle, c.byref(value), c.byref(result))
        require(transport == OK and result.struct_size == c.sizeof(Outcome) and result.api_version == RESOURCE_API_VERSION
            and result.sequence == value.sequence and result.disposition in (1, 2, 3), f"resource outcome unknown/invalid: {transport}")
        require(result.status == status, f"resource outcome={result.status}, expected={status}")
        if disposition is not None:
            require(result.disposition == disposition, "resource receipt disposition differs")
        self.evidence.setdefault("resource_outcomes", []).append(known(result))
        return result


def preserve(path, destination, evidence):
    path, destination = check_root(path), check_root(destination)
    require(not destination.exists(), "synthetic replacement would overwrite evidence")
    path.rename(destination)
    evidence.setdefault("preserved_synthetic_files", []).append({"from": str(path), "to": str(destination)})


def protected(runtime):
    return {"document": document_state(runtime), "history": history_bytes(runtime.data), "station": listing(runtime)}


def resource_files(data):
    # Host owns an exclusive live host.lock and updates its status separately.
    # Compare the exact declarations a resource probe promises not to mutate.
    result = {"versions": retained_files(data)}
    for name in ("session/external-sources.json", "library/catalog.json", "documents/history.txt"):
        path = check_root(data / name)
        result[name] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    return result


def native_versions(dll, resource, root, evidence):
    case = root / "versions"
    case.mkdir()
    source, relocated, newer, latest = [check_root(case / name) for name in ("source-A.png", "moved-A.png", "candidate-B.png", "candidate-C.png")]
    a, b, cc = tiny_png(COLOR_A), tiny_png(COLOR_B), tiny_png(COLOR_C)
    for path, data in ((source, a), (relocated, a), (newer, b), (latest, cc)):
        path.write_bytes(data)
    runtime = Native(dll, resource, case / "data", evidence)
    try:
        empty = runtime.view()
        require(empty["stamp"][2] == 0 and not empty["body"]["resources"], "empty catalog revision zero was rejected")
        handle = import_source(runtime, source)
        runtime.submit_edit("editor.asset.insert", str(handle))
        job = runtime.submit_edit("editor.export.png", "session://exports/queued-A.png", ACCEPTED).task_id
        frozen_work = protected(runtime)
        baseline = hashes(runtime.data)
        proof = runtime.probe(relocated, RELOCATE)
        runtime.probe(relocated, RELOCATE)
        require(hashes(runtime.data) == baseline and protected(runtime) == frozen_work,
            "probe wrote data/authorization/retention or changed document/Station")
        evidence["checks"].append("probe_is_stateless_and_side_effect_free_even_when_repeated")
        preserve(source, case / "retired-original-A.png", evidence)
        first = runtime.apply(request(proof, relocated))
        assert_projection(runtime, handle, a)
        require(first.resource_id == 1 and first.stamp.revision == proof.stamp.revision + 1
            and runtime.view()["body"]["resources"][0]["sha256"] == hashlib.sha256(a).hexdigest()
            and protected(runtime) == frozen_work, "relocate did not preserve resource identity/content and old consumers")
        runtime.probe(newer, RELOCATE, status=MISMATCH)
        evidence["checks"].append("relocate_repairs_missing_path_only_for_same_content_and_preserves_consumers")
        before = runtime.view()
        short = c.create_string_buffer(b"\xa5" * 3, 3)
        actual, info, length = runtime.raw_resources(Stamp(*before["stamp"]), short)
        require(actual == SMALL and short.raw == b"\xa5" * 3 and length == info.text_len,
            "short resource snapshot buffer was overwritten")
        runtime.legacy("library.rename", "1 renamed.png")
        sentinel = c.create_string_buffer(b"\xa5" * 65536, 65536)
        actual, info, length = runtime.raw_resources(Stamp(*before["stamp"]), sentinel)
        require(actual == STALE and length == info.text_len == 0 and sentinel.raw == b"\xa5" * 65536,
            "stale snapshot exposed mixed bytes")
        wrong = Stamp(*runtime.view()["stamp"])
        wrong.epoch_hi ^= 1
        require(runtime.raw_resources(wrong, sentinel)[0] == WRONG_EPOCH, "resource snapshot ignored epoch")
        evidence["checks"].append("coherent_snapshot_short_buffer_stale_and_wrong_epoch_fail_without_bytes")
        newer_proof = runtime.probe(newer)
        saved_request = request(newer_proof, newer, seq=2)
        adopted = runtime.apply(saved_request)
        assert_projection(runtime, handle, a)
        require(protected(runtime) == frozen_work and adopted.resource_id == 1, "adopt changed document/history/Station")
        assert_pin(runtime.data, hashlib.sha256(b).hexdigest(), b)
        latest_proof = runtime.probe(latest)
        runtime.apply(request(latest_proof, latest, client=(0xC2B3, 0xC2B4)))
        after_latest = runtime.view()
        assert_projection(runtime, handle, a)
        preserve(newer, case / "retired-candidate-B.png", evidence)
        repeated = runtime.apply(saved_request, disposition=2)
        require(known(repeated) == {**known(adopted), "disposition": 2} and runtime.view() == after_latest,
            "lost-reply retry checked removed candidate or regressed later head")
        conflict = request(newer_proof, latest, seq=2)
        runtime.apply(conflict, CONFLICT)
        require(runtime.view() == after_latest, "token conflict changed head")
        evidence["checks"].append("adopt_retains_new_bytes_and_lost_reply_replay_never_reapplies_over_later_head")
        runtime.drain()
        assert_output(row(runtime, job), runtime.data / "exports/queued-A.png", COLOR_A)
        require(source_read(runtime, "library://1", hashlib.sha256(a).hexdigest()) == a
            and source_read(runtime, "library://1", hashlib.sha256(b).hexdigest()) == b
            and source_read(runtime, "library://1") == cc, "old retained/current versions were confused")
        runtime.legacy("asset.open", "library://1", ACCEPTED)
        new_handle = next(value for value in listing(runtime) if value != handle)
        runtime.submit_edit("editor.asset.insert", str(new_handle))
        new_job = runtime.submit_edit("editor.export.png", "session://exports/new-C.png", ACCEPTED).task_id
        runtime.drain()
        assert_output(row(runtime, new_job), runtime.data / "exports/new-C.png", COLOR_C)
        runtime.submit_edit("history.undo")
        require(hashlib.sha256(a).hexdigest() in runtime.snapshot()[1].decode(), "history old source was rebound")
        evidence["checks"].append("queued_job_old_document_history_and_new_insert_consume_their_fixed_versions")
        # Known refusals consume sequence; retained receipts expire without replaying IO.
        for seq in range(3, 70):
            runtime.apply(request(newer_proof, newer, seq=seq), STALE)
        runtime.apply(saved_request, EXPIRED)
        evidence["checks"].append("expired_receipts_keep_high_water_and_refuse_reexecution")
        old_epoch_request = request(runtime.probe(latest), latest, client=(0xC2B5, 0xC2B6))
        runtime.legacy("doc.save", "session://saved.cut")
    finally:
        runtime.close()
    runtime = Native(dll, resource, case / "data", evidence)
    try:
        runtime.apply(old_epoch_request, WRONG_EPOCH)
        require(runtime.view()["body"] == after_latest["body"], "cold restore changed accepted library declaration")
        require(source_read(runtime, "library://1", hashlib.sha256(a).hexdigest()) == a, "cold retained old version failed")
        evidence["checks"].append("cold_restore_keeps_bindings_versions_and_rejects_old_epoch_pending")
    finally:
        runtime.close()


def candidate_failures(dll, resource, root, evidence):
    case = root / "failures"
    case.mkdir()
    source, candidate = case / "A.png", case / "candidate.png"
    a, b, cc = tiny_png(COLOR_A), tiny_png(COLOR_B), tiny_png(COLOR_C)
    source.write_bytes(a)
    candidate.write_bytes(b)
    runtime = Native(dll, resource, case / "data", evidence)
    try:
        import_source(runtime, source)
        initial = runtime.view()
        proof = runtime.probe(candidate)
        candidate.write_bytes(cc)
        runtime.apply(request(proof, candidate), CANDIDATE_CHANGED)
        candidate.write_bytes(b)
        proof = runtime.probe(candidate)
        preserve(candidate, case / "old-candidate-object.png", evidence)
        candidate.write_bytes(b)
        runtime.apply(request(proof, candidate, seq=2), CANDIDATE_CHANGED)
        require(runtime.view() == initial, "changed candidate published a resource head")
        evidence["checks"].append("proof_rejects_content_change_and_same_bytes_new_file_identity")
        proof = runtime.probe(candidate)
        blocked = check_root(runtime.data / "library/versions/1")
        blocked.parent.mkdir(parents=True, exist_ok=True)
        blocked.write_bytes(b"owned C2b blocker")
        operation = request(proof, candidate, seq=3)
        before = hashes(runtime.data)
        runtime.apply(operation, FAILED)
        require(runtime.view() == initial and hashes(runtime.data) == before, "version failure published dependencies/head or erased blocker")
        preserve(blocked, case / "retired-version-blocker", evidence)
        runtime.apply(operation, FAILED, disposition=2)
        auth = runtime.data / "session/external-sources.json"
        before_auth = auth.read_bytes()
        kernel, lock = exclusive_file(auth)
        try:
            runtime.apply(request(proof, candidate, seq=4), FAILED)
        finally:
            kernel.CloseHandle(lock)
        require(auth.read_bytes() == before_auth and runtime.view() == initial, "auth failure changed grant/catalog")
        assert_pin(runtime.data, hashlib.sha256(b).hexdigest(), b)
        catalog = runtime.data / "library/catalog.json"
        kernel, lock = exclusive_file(catalog)
        try:
            locked_request = request(proof, candidate, seq=5)
            runtime.apply(locked_request, FAILED)
        finally:
            kernel.CloseHandle(lock)
        require(runtime.view() == initial, "catalog failure published a half head")
        orphan_auth = json.loads(auth.read_text())["sources"]
        require(len(orphan_auth) == 2, "expected dependency-first unreferenced grant was not retained")
        runtime.apply(locked_request, FAILED, disposition=2)
        runtime.apply(request(proof, candidate, seq=6))
        require(len(json.loads(auth.read_text())["sources"]) == 2, "retry duplicated immutable authorization")
        runtime.legacy("library.detach", "1")
        runtime.probe(candidate, status=WRONG_KIND)
        evidence["checks"].append("version_auth_catalog_failures_keep_head_and_failure_receipts_with_documented_orphans")
        evidence["checks"].append("owned_resources_refuse_external_rebinding")
    finally:
        runtime.close()


def same_path_binding(dll, resource, root, evidence):
    case = root / "same-path"
    case.mkdir()
    source = case / "source.png"
    a, b = tiny_png(COLOR_A), tiny_png(COLOR_B)
    source.write_bytes(a)
    runtime = Native(dll, resource, case / "data", evidence)
    try:
        handle = import_source(runtime, source)
        runtime.submit_edit("editor.asset.insert", str(handle))
        preserve(source, case / "old-file-object-A.png", evidence)
        source.write_bytes(b)
        runtime.legacy("asset.open", "library://1", FAILED)
        runtime.apply(request(runtime.probe(source), source))
        auth = json.loads((runtime.data / "session/external-sources.json").read_text())["sources"]
        require(len(auth) == 2 and auth[0]["path"].lower() == auth[1]["path"].lower()
            and auth[0]["file_index"] != auth[1]["file_index"], "same path replacement mutated old grant identity")
        source_read(runtime, f"external://{auth[0]['id']}", expected=FAILED)
    finally:
        runtime.close()
    runtime = Native(dll, resource, case / "data", evidence)
    try:
        require(source_read(runtime, "library://1") == b
            and source_read(runtime, "library://1", hashlib.sha256(a).hexdigest()) == a,
            "cold same-path binding restore lost old/new versions")
        evidence["checks"].append("same_path_new_object_gets_new_binding_without_reauthorizing_old_grant_and_restores")
    finally:
        runtime.close()


def concurrent_resources(dll, resource, root, evidence):
    case = root / "concurrent"
    case.mkdir()
    source, candidate_b, candidate_c = [case / name for name in ("A.png", "B.png", "C.png")]
    for path, pixel in ((source, COLOR_A), (candidate_b, COLOR_B), (candidate_c, COLOR_C)):
        path.write_bytes(tiny_png(pixel))
    runtime = Native(dll, resource, case / "data", evidence)
    try:
        import_source(runtime, source)
        proof = runtime.probe(candidate_b)
        same = request(proof, candidate_b)
        def send(value):
            result = Outcome()
            status = runtime.resources.submit(runtime.handle, c.byref(value), c.byref(result))
            require(status == OK and result.sequence == value.sequence and result.disposition in (1, 2, 3),
                "concurrent actual DLL request returned unknown or unrelated outcome")
            return known(result)
        with ThreadPoolExecutor(max_workers=8) as pool:
            duplicate = list(pool.map(send, [same] * 8))
        require(all(value["status"] == OK for value in duplicate)
            and sum(value["disposition"] == 1 for value in duplicate) == 1
            and runtime.view()["stamp"][2] == proof.stamp.revision + 1, "same resource token executed more than once")
        proof = runtime.probe(candidate_c)
        competing = [request(proof, candidate_c, client=(0xC2B20, i + 1)) for i in range(8)]
        with ThreadPoolExecutor(max_workers=8) as pool:
            outcomes = list(pool.map(send, competing))
        require(sum(value["status"] == OK for value in outcomes) == 1
            and sum(value["status"] == STALE for value in outcomes) == 7
            and runtime.view()["stamp"][2] == proof.stamp.revision + 1, "same-stamp resource writers were not serialized")
        evidence["resource_concurrency"] = {"same_token": duplicate, "same_stamp_clients": outcomes}
        evidence["checks"].append("actual_DLL_eight_same_token_threads_and_eight_competing_clients_publish_once")
    finally:
        runtime.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("resource-operations"))
    args = parser.parse_args()
    require(os.name == "nt", "C2b real DLL/Host verification requires Windows")
    root = claim(args.root)
    portable = (OUTPUT / "portable").resolve()
    before = hashes(portable)
    evidence = {"format": "cutrans-resource-operations-verification/1", "root": str(root), "checks": [],
        "artifact_hashes": before, "passed": False, "limits": ["No GUI/IME/installer/system registration/release acceptance",
        "Receipts are incarnation-local, not durable exactly-once", "Immutable dependencies may remain after catalog failure; no garbage collection"]}
    try:
        dll = c.WinDLL(str(portable / "runtime/cutrans_vm_runtime.dll"))
        configure(dll)
        require(dll.cutrans_vm_abi_version() == identity()["host_api"] and identity()["host_api"] >= 10, "wrong actual ABI for resource API v2")
        native_versions(dll, portable / "runtime", root, evidence)
        candidate_failures(dll, portable / "runtime", root, evidence)
        same_path_binding(dll, portable / "runtime", root, evidence)
        concurrent_resources(dll, portable / "runtime", root, evidence)
        require(hashes(portable) == before and not (portable / "data").exists(), "C2b verification changed artifact/data")
        evidence["passed"] = True
        print(f"CUTRANS_RESOURCE_OPERATIONS_VERIFY_OK checks={len(evidence['checks'])} evidence={root}")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        evidence["artifact_hashes_after"] = hashes(portable)
        (root / "report.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)


if __name__ == "__main__":
    main()
