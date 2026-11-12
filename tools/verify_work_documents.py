"""Verify Resource API v3 working bodies on the real DLL and Host.

Only synthetic claimed roots are changed. Old jobs keep their fixed input while
working text and drafts advance independently. No GUI or installation is used.
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
from verify_host import invoke
from verify_input import ByteSlice, hashes
from verify_jobs import ACCEPTED, OK, SMALL, require, tiny_png
from verify_resource_operations import Native, configure
from verify_resource_registration import acquire
from verify_resource_versions import (COLOR_A, COLOR_B, assert_output, document_state,
    history_bytes, host_rpc, row, source_read)
from verify_workspace import Stamp
from verify_workspace_rpc import Pipe, Workspace

VERSION = 4
CREATE, SAVE_DRAFT, COMMIT, DISCARD = 1, 2, 3, 4
SNAPSHOT_SIZE, OUTCOME_SIZE, REQUEST_HEADER = 144, 104, 80


class WorkSnapshot(c.Structure):
    _fields_ = [("struct_size", c.c_uint32), ("api_version", c.c_uint32), ("stamp", Stamp),
        ("resource_id", c.c_uint64), ("work_revision", c.c_uint64), ("base_revision", c.c_uint64),
        ("draft_revision", c.c_uint64), ("body_origin", c.c_uint32), ("reserved", c.c_uint32),
        ("content_hash", c.c_ubyte * 32), ("body_hash", c.c_ubyte * 32), ("body_len", c.c_size_t)]


class WorkRequest(c.Structure):
    _fields_ = [("struct_size", c.c_uint32), ("api_version", c.c_uint32),
        ("client_hi", c.c_uint64), ("client_lo", c.c_uint64), ("sequence", c.c_uint64),
        ("resource_id", c.c_uint64), ("base_revision", c.c_uint64), ("expected_draft_revision", c.c_uint64),
        ("mode", c.c_uint32), ("reserved", c.c_uint32), ("label", ByteSlice), ("body", ByteSlice)]


class WorkOutcome(c.Structure):
    _fields_ = [("struct_size", c.c_uint32), ("api_version", c.c_uint32), ("status", c.c_int32),
        ("disposition", c.c_uint32), ("sequence", c.c_uint64), ("stamp", Stamp),
        ("resource_id", c.c_uint64), ("work_revision", c.c_uint64), ("draft_revision", c.c_uint64),
        ("content_hash", c.c_ubyte * 32)]


WorkSnapshotFn = c.CFUNCTYPE(c.c_int32, c.c_void_p, c.c_uint64, c.POINTER(WorkSnapshot),
    c.POINTER(WorkSnapshot), c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t))
WorkSubmitFn = c.CFUNCTYPE(c.c_int32, c.c_void_p, c.POINTER(WorkRequest), c.POINTER(WorkOutcome))


def byte_slice(content):
    storage = c.create_string_buffer(content)
    return ByteSlice(c.cast(storage, c.c_void_p), len(content)), storage


def request(sequence, mode, resource_id=0, base=0, draft=0, label=b"", body=b"", client=(0xD301, 0xD302)):
    label_value, label_storage = byte_slice(label)
    body_value, body_storage = byte_slice(body)
    result = WorkRequest(c.sizeof(WorkRequest), VERSION, *client, sequence, resource_id,
        base, draft, mode, 0, label_value, body_value)
    result._storage = (label_storage, body_storage)
    return result


def sha(content):
    return hashlib.sha256(content).hexdigest()


class WorkClient(Native):
    def submit_work(self, value, expected=OK, disposition=None):
        outcome = WorkOutcome()
        submit = c.cast(self.resources.work_submit, WorkSubmitFn)
        transport = submit(self.handle, c.byref(value), c.byref(outcome))
        require(transport == OK and outcome.struct_size == c.sizeof(WorkOutcome)
            and outcome.api_version == VERSION and outcome.sequence == value.sequence
            and outcome.disposition in (1, 2, 3), f"work outcome is unknown or malformed: {transport}")
        require(outcome.status == expected, f"work outcome={outcome.status}, expected={expected}")
        if disposition is not None:
            require(outcome.disposition == disposition, "work receipt disposition differs")
        return outcome

    def work_snapshot(self, resource_id):
        read = c.cast(self.resources.work_snapshot, WorkSnapshotFn)
        metadata, required = WorkSnapshot(), c.c_size_t(999)
        query = read(self.handle, resource_id, None, c.byref(metadata), None, 0, c.byref(required))
        require(query == SMALL and metadata.struct_size == c.sizeof(WorkSnapshot)
            and metadata.api_version == VERSION and metadata.resource_id == resource_id
            and metadata.body_len == required.value and required.value <= 16 * 1024 * 1024,
            f"work snapshot query failed: {query}")
        output = c.create_string_buffer(max(1, required.value))
        actual, copied = WorkSnapshot(), c.c_size_t(999)
        status = read(self.handle, resource_id, c.byref(metadata), c.byref(actual), output,
            len(output), c.byref(copied))
        require(status == OK and copied.value == required.value and actual.resource_id == resource_id
            and actual.work_revision == metadata.work_revision and actual.base_revision == metadata.base_revision
            and actual.draft_revision == metadata.draft_revision and actual.body_origin == metadata.body_origin
            and bytes(actual.content_hash) == bytes(metadata.content_hash)
            and bytes(actual.body_hash) == bytes(metadata.body_hash),
            f"work snapshot changed across the two reads: {status}")
        body = output.raw[:required.value]
        require(sha(body) == bytes(actual.body_hash).hex(), "work body hash differs from its bytes")
        return actual, body


def fixed_version_case(library, runtime_dir, root, evidence):
    case = check_root(root / "fixed-version")
    case.mkdir()
    runtime = WorkClient(library, runtime_dir, case / "data", evidence)
    create = request(1, CREATE, label=b"fixed.png", body=tiny_png(COLOR_A))
    draft = commit = None
    try:
        created = runtime.submit_work(create)
        require(created.resource_id == 1 and created.work_revision == 1, "work creation did not publish revision one")
        handle = acquire(runtime, created.resource_id, tiny_png(COLOR_A))
        runtime.submit_edit("editor.asset.insert", str(handle))
        task_id = runtime.submit_edit("editor.export.png", "session://exports/fixed-old.png", ACCEPTED).task_id
        before = (document_state(runtime), history_bytes(runtime.data), runtime.all_jobs())
        draft = request(2, SAVE_DRAFT, created.resource_id, 1, 0, body=tiny_png(COLOR_B))
        saved = runtime.submit_work(draft)
        require(saved.work_revision == 1 and saved.draft_revision > 0
            and source_read(runtime, "library://1") == tiny_png(COLOR_A),
            "saving a draft advanced the published work head")
        commit = request(3, COMMIT, created.resource_id, 0, saved.draft_revision)
        committed = runtime.submit_work(commit)
        require(committed.work_revision == 2 and committed.draft_revision == 0,
            "commit did not advance exactly one work revision")
        require(before == (document_state(runtime), history_bytes(runtime.data), runtime.all_jobs()),
            "working body mutation rewrote the old document, History or JobSpec")
        runtime.drain()
        output = assert_output(row(runtime, task_id), runtime.data / "exports/fixed-old.png", COLOR_A)
        require(source_read(runtime, "library://1") == tiny_png(COLOR_B)
            and source_read(runtime, "library://1", sha(tiny_png(COLOR_A))) == tiny_png(COLOR_A),
            "fixed and current versions were confused after commit")
        evidence["fixed_job_output"] = output
        evidence["checks"].append("draft_does_not_advance_head_commit_preserves_old_document_history_queued_job_and_fixed_export")
    finally:
        runtime.close()
    runtime = WorkClient(library, runtime_dir, case / "data", evidence)
    try:
        metadata, body = runtime.work_snapshot(1)
        require(metadata.work_revision == 2 and metadata.draft_revision == 0 and body == tiny_png(COLOR_B),
            "cold restore did not reload the committed work body")
        require(source_read(runtime, "library://1", sha(tiny_png(COLOR_A))) == tiny_png(COLOR_A),
            "cold restore lost the old fixed version")
        replay = runtime.submit_work(commit, disposition=2)
        require(replay.work_revision == 2 and replay.draft_revision == 0, "cold commit replay advanced the head")
        created_again = runtime.submit_work(create, disposition=2)
        require(created_again.resource_id == 1 and len(runtime.view()["body"]["resources"]) == 1,
            "cold create replay duplicated a resource")
        evidence["checks"].append("cold_restore_reloads_work_and_fixed_versions_and_persistent_receipts_prevent_duplicate_effects")
    finally:
        runtime.close()


def receipt_ring_case(library, runtime_dir, root, evidence):
    """A bounded receipt ring must not cap successful work for its lifetime."""
    case = check_root(root / "receipt-ring")
    case.mkdir()
    runtime = WorkClient(library, runtime_dir, case / "data", evidence)
    try:
        created = runtime.submit_work(request(1, CREATE, label=b"ring.txt", body=b"base"))
        require(created.resource_id == 1 and created.work_revision == 1, "ring fixture creation failed")
        draft = 0
        last = None
        for index in range(70):
            body = f"draft-{index}".encode()
            last = runtime.submit_work(request(2 + index, SAVE_DRAFT, 1, 1, draft, body=body))
            draft = last.draft_revision
        require(last is not None and last.status == OK and draft != 0, "work stopped accepting drafts at the receipt boundary")
        metadata, body = runtime.work_snapshot(1)
        require(metadata.draft_revision == draft and body == b"draft-69", "latest draft was lost after ring eviction")
        committed = runtime.submit_work(request(72, COMMIT, 1, 0, draft))
        require(committed.work_revision == 2 and committed.draft_revision == 0, "commit after ring eviction failed")
        evicted = runtime.submit_work(request(2, SAVE_DRAFT, 1, 2, 0, body=b"evicted"), expected=67, disposition=3)
        require(evicted.status == 67, "an evicted sequence was not refused as expired")
        require(runtime.work_snapshot(1)[1] == b"draft-69", "an evicted sequence executed again")
        evidence["checks"].append("bounded_receipt_ring_keeps_work_usable_and_refuses_evicted_sequences")
    finally:
        runtime.close()


def host_request(value):
    label, body = value.label, value.body
    label_bytes = c.string_at(label.ptr, label.len) if label.len else b""
    body_bytes = c.string_at(body.ptr, body.len) if body.len else b""
    return struct.pack("<II6QII2Q", c.sizeof(WorkRequest), VERSION, value.client_hi, value.client_lo, value.sequence,
        value.resource_id, value.base_revision, value.expected_draft_revision, value.mode, 0,
        len(label_bytes), len(body_bytes)) + label_bytes + body_bytes


def host_submit(wire, payload, disposition=None):
    status, value, raw = host_rpc(wire, 30, payload)
    require(status == value == 0 and len(raw) == OUTCOME_SIZE, f"Host work outcome failed: {status}")
    outcome = WorkOutcome.from_buffer_copy(raw)
    require(outcome.struct_size == c.sizeof(WorkOutcome) and outcome.api_version == VERSION
        and outcome.sequence == struct.unpack_from("<Q", payload, 24)[0]
        and outcome.disposition in (1, 2, 3), "invalid Host work outcome")
    if disposition is not None:
        require(outcome.disposition == disposition, "Host did not replay the persistent work receipt")
    return outcome


def discard_host_reply(wire, payload):
    header = struct.pack("<8sIIQII", b"CUTRSH2\0", 30, 0, 0, len(payload), 0)
    wire.frames.append({"kind": 30, "request_header": header.hex(), "request_payload": payload.hex(),
        "response_deliberately_not_read": True})
    connection = Pipe(wire.endpoint)
    try:
        connection.write(header)
        connection.write(payload)
    finally:
        connection.close()


def host_snapshot(wire, resource_id):
    status, value, raw = host_rpc(wire, 29, identity=resource_id)
    require(status == value == 0 and len(raw) >= SNAPSHOT_SIZE, f"Host work snapshot failed: {status}")
    metadata = WorkSnapshot.from_buffer_copy(raw[:SNAPSHOT_SIZE])
    expected = raw[:SNAPSHOT_SIZE]
    status, value, second = host_rpc(wire, 29, expected, identity=resource_id)
    require(status == value == 0 and second == raw, "Host work snapshot changed between reads")
    body = raw[SNAPSHOT_SIZE:]
    require(metadata.resource_id == resource_id and metadata.body_len == len(body)
        and sha(body) == bytes(metadata.body_hash).hex(), "Host returned an inconsistent work body")
    return metadata, body


def host_case(console, root, evidence):
    data = check_root(root / "host data")
    wire = Workspace(data, evidence)
    stopped = False
    try:
        _, started = invoke(console, "start", data, "portable")
        require(started["state"] == "running", "work Host did not start")
        create = host_request(request(1, CREATE, label=b"host-note.txt", body=b"host old"))
        discard_host_reply(wire, create)
        created = host_submit(wire, create, 2)
        require(created.resource_id == 1 and created.work_revision == 1,
            "lost create reply duplicated or lost the resource")
        draft = host_request(request(2, SAVE_DRAFT, 1, 1, 0, body=b"host new"))
        saved = host_submit(wire, draft, 1)
        require(saved.work_revision == 1 and saved.draft_revision > 0, "Host draft advanced the work head")
        commit = host_request(request(3, COMMIT, 1, 0, saved.draft_revision))
        committed = host_submit(wire, commit, 1)
        require(committed.work_revision == 2 and committed.draft_revision == 0, "Host commit did not publish revision two")
        metadata, body = host_snapshot(wire, 1)
        require(metadata.work_revision == 2 and body == b"host new", "Host snapshot returned another generation")
        _, stopped_result = invoke(console, "stop", data, "portable")
        require(stopped_result["state"] == "stopped", "work Host did not stop")
        stopped = True
        invoke(console, "start", data, "portable")
        stopped = False
        replay = host_submit(wire, commit, 2)
        require(replay.work_revision == 2 and host_snapshot(wire, 1)[1] == b"host new",
            "Host restart lost the work receipt or current body")
        _, stopped_result = invoke(console, "stop", data, "portable")
        require(stopped_result["state"] == "stopped", "restarted work Host did not stop")
        stopped = True
        evidence["checks"].append("host_lost_reply_replay_and_restart_preserve_work_draft_commit_and_persistent_receipts")
        evidence["host_stopped"] = True
    finally:
        if not stopped:
            try:
                invoke(console, "stop", data, "portable")
                evidence["host_stopped"] = True
            except Exception as error:
                evidence["host_cleanup_error"] = repr(error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("work-documents"))
    args = parser.parse_args()
    require(os.name == "nt" and identity()["host_api"] >= 10, "real work verification requires Windows and ABI10+")
    root = claim(args.root)
    portable = (OUTPUT / "portable").resolve()
    before = hashes(portable)
    evidence = {"format": "cutrans-work-documents-verification/1", "root": str(root),
        "artifact_hashes": before, "checks": [], "passed": False}
    try:
        library = c.WinDLL(str(portable / "runtime/cutrans_vm_runtime.dll"))
        configure(library)
        fixed_version_case(library, portable / "runtime", root, evidence)
        receipt_ring_case(library, portable / "runtime", root, evidence)
        host_case(portable / "cutrans_vm.exe", root, evidence)
        require(hashes(portable) == before, "work verification modified the tested artifact")
        evidence["passed"] = True
        print("CUTRANS_WORK_DOCUMENTS_VERIFY_OK fixed_job=1 draft_commit=1 ring=1 cold_receipt=1 host_lost_reply=1 host_restart=1")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        (root / "work-documents.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)
        print(f"Work document evidence retained: {root}")


if __name__ == "__main__":
    main()
