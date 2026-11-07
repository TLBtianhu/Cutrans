"""Exercise workspace API v1 against the distributed Runtime DLL."""
from __future__ import annotations

import ctypes
import json
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from product import identity
from verification_context import mark_data
from verification_paths import check_root, claim, default_root, retain
from verify_edit_commit import exclusive_file, node_ids
from verify_input import ByteSlice, Config, hashes, string_slice


OK, FAILED, SMALL = 0, 8, 15
STALE, WRONG_EPOCH, CONFLICT, EXPIRED, BAD_SEQUENCE, UNSUPPORTED = 16, 17, 18, 19, 20, 22
EXECUTED, REPLAYED, REJECTED = 1, 2, 3
RECEIPT_CAPACITY = 64


class Stamp(ctypes.Structure):
    _fields_ = [("epoch_hi", ctypes.c_uint64), ("epoch_lo", ctypes.c_uint64), ("revision", ctypes.c_uint64)]


class Request(ctypes.Structure):
    _fields_ = [("struct_size", ctypes.c_uint32), ("api_version", ctypes.c_uint32),
                ("client_hi", ctypes.c_uint64), ("client_lo", ctypes.c_uint64), ("sequence", ctypes.c_uint64),
                ("expected", Stamp), ("name", ByteSlice), ("arg", ByteSlice)]


class Outcome(ctypes.Structure):
    _fields_ = [("struct_size", ctypes.c_uint32), ("api_version", ctypes.c_uint32),
                ("status", ctypes.c_int32), ("disposition", ctypes.c_uint32), ("sequence", ctypes.c_uint64),
                ("stamp", Stamp), ("created_id", ctypes.c_uint64), ("task_id", ctypes.c_uint64)]


class Snapshot(ctypes.Structure):
    _fields_ = [("struct_size", ctypes.c_uint32), ("api_version", ctypes.c_uint32), ("stamp", Stamp),
                ("fingerprint", ctypes.c_uint64), ("node_id_high_water", ctypes.c_uint64),
                ("flags", ctypes.c_uint32), ("reserved", ctypes.c_uint32), ("text_len", ctypes.c_size_t)]


SnapshotFn = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, ctypes.POINTER(Stamp), ctypes.POINTER(Snapshot),
                              ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t))
SubmitFn = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, ctypes.POINTER(Request), ctypes.POINTER(Outcome))


class WorkspaceApi(ctypes.Structure):
    _fields_ = [("struct_size", ctypes.c_uint32), ("api_version", ctypes.c_uint32), ("context", ctypes.c_void_p),
                ("snapshot", SnapshotFn), ("submit", SubmitFn)]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def stamp(value):
    return value.epoch_hi, value.epoch_lo, value.revision


def metadata(value):
    return stamp(value.stamp), value.fingerprint, value.node_id_high_water, value.flags, value.text_len


def outcome(value):
    # Replay changes the disposition, but preserves the original result and stamp.
    return value.status, value.sequence, stamp(value.stamp), value.created_id, value.task_id


def request(sequence, expected, name, arg=None, client=(0x43555452414E53, 1)):
    name_value, name_storage = string_slice(name)
    arg_value, arg_storage = string_slice(arg) if arg is not None else (ByteSlice(), None)
    value = Request(ctypes.sizeof(Request), 1, *client, sequence, expected, name_value, arg_value)
    value._storage = name_storage, arg_storage
    return value


def configure(library):
    library.cutrans_vm_abi_version.restype = ctypes.c_uint32
    library.cutrans_vm_create.argtypes = [ctypes.POINTER(Config), ctypes.POINTER(ctypes.c_void_p)]
    library.cutrans_vm_create.restype = ctypes.c_int32
    library.cutrans_vm_destroy.argtypes = [ctypes.c_void_p]
    library.cutrans_vm_destroy.restype = None
    library.cutrans_vm_workspace_api.argtypes = [ctypes.c_void_p, ctypes.POINTER(WorkspaceApi)]
    library.cutrans_vm_workspace_api.restype = ctypes.c_int32
    library.cutrans_vm_document_snapshot.argtypes = SnapshotFn._argtypes_
    library.cutrans_vm_document_snapshot.restype = ctypes.c_int32
    library.cutrans_vm_document_submit.argtypes = SubmitFn._argtypes_
    library.cutrans_vm_document_submit.restype = ctypes.c_int32


class Runtime:
    def __init__(self, library, resource, data, host_api):
        self.library = library
        self.handle = ctypes.c_void_p()
        self.data = mark_data(data, "portable", resource)
        resource_value, resource_storage = string_slice(str(resource))
        data_value, data_storage = string_slice(str(self.data))
        config = Config(ctypes.sizeof(Config), host_api, 1, 0, resource_value, data_value)
        status = library.cutrans_vm_create(ctypes.byref(config), ctypes.byref(self.handle))
        require(status == OK and self.handle.value, f"isolated Runtime creation failed: {status}")
        try:
            self.api = WorkspaceApi()
            status = library.cutrans_vm_workspace_api(self.handle, ctypes.byref(self.api))
            require(status == OK and self.api.struct_size == ctypes.sizeof(WorkspaceApi) and self.api.api_version == 1,
                    "Runtime did not expose workspace API v1")
            require(self.api.context == self.handle.value and bool(self.api.snapshot) and bool(self.api.submit),
                    "workspace table has a wrong context or missing functions")
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.handle.value:
            self.library.cutrans_vm_destroy(self.handle)
            self.handle = ctypes.c_void_p()

    def raw_snapshot(self, expected=None, buffer=None, function=None):
        info, required = Snapshot(), ctypes.c_size_t(999)
        status = (function or self.api.snapshot)(self.api.context, ctypes.byref(expected) if expected is not None else None,
                                                ctypes.byref(info), buffer, len(buffer) if buffer is not None else 0,
                                                ctypes.byref(required))
        require(info.struct_size == ctypes.sizeof(Snapshot) and info.api_version == 1 and info.reserved == 0,
                "snapshot returned an invalid header")
        return status, info, required.value

    def snapshot(self):
        status, first, required = self.raw_snapshot()
        require(status == SMALL and required == first.text_len and required > 0, "snapshot size query failed")
        buffer = ctypes.create_string_buffer(required)
        status, second, written = self.raw_snapshot(first.stamp, buffer)
        require(status == OK and metadata(first) == metadata(second) and written == required,
                "snapshot metadata and canonical text did not share one version")
        return second, buffer.raw[:written]

    def submit(self, value, expected_status=None, disposition=None, function=None):
        result = Outcome()
        status = (function or self.api.submit)(self.api.context, ctypes.byref(value), ctypes.byref(result))
        require(status == OK, f"submit transport failed: {status}")
        require(result.struct_size == ctypes.sizeof(Outcome) and result.api_version == 1 and result.sequence == value.sequence,
                "submit returned an invalid outcome header or sequence")
        require(result.task_id == 0, "synchronous edit/rejection returned a task ID")
        if expected_status is not None:
            require(result.status == expected_status, f"command result={result.status}, expected={expected_status}")
        if disposition is not None:
            require(result.disposition == disposition, f"disposition={result.disposition}, expected={disposition}")
        return result


def state(value):
    info, text = value
    return metadata(info), text


def unchanged(runtime, baseline, message):
    require(state(runtime.snapshot()) == state(baseline), message)


def rejected_snapshot(runtime, expected, status):
    buffer = ctypes.create_string_buffer(b"\xa5" * 65536, 65536)
    before = buffer.raw
    actual, info, required = runtime.raw_snapshot(expected, buffer)
    require(actual == status and required == 0 and info.text_len == 0 and buffer.raw == before,
            "rejected snapshot overwrote caller bytes or exposed a mixed-version payload")


def sequential(runtime, checks):
    initial = runtime.snapshot()
    status, exported, required = runtime.raw_snapshot(function=runtime.library.cutrans_vm_document_snapshot)
    require(status == SMALL and required == len(initial[1]) and metadata(exported) == metadata(initial[0]),
            "exported snapshot and workspace table disagree")
    first_request = request(1, initial[0].stamp, "editor.invert.add", "c1")
    first = runtime.submit(first_request, OK, EXECUTED, function=runtime.library.cutrans_vm_document_submit)
    changed = runtime.snapshot()
    created = set(node_ids(changed[1])) - set(node_ids(initial[1]))
    require(created == {first.created_id} and first.created_id > 1 and changed[0].stamp.revision == initial[0].stamp.revision + 1,
            "node creation did not return its single published node ID and revision")
    require(stamp(first.stamp) == stamp(changed[0].stamp), "outcome stamp is not the committed document stamp")
    replay = runtime.submit(first_request, OK, REPLAYED)
    require(outcome(replay) == outcome(first), "duplicate request changed the original outcome")
    runtime.submit(request(1, initial[0].stamp, "editor.invert.add", "c0"), CONFLICT, REJECTED)
    runtime.submit(request(1, changed[0].stamp, "editor.invert.add", "c1"), CONFLICT, REJECTED)
    runtime.submit(request(4, changed[0].stamp, "history.undo"), BAD_SEQUENCE, REJECTED)
    unchanged(runtime, changed, "replay/conflict/bad sequence changed the document")
    checks.append("duplicate_created_once_conflicts_include_payload_and_expected_stamp")

    rejected_snapshot(runtime, initial[0].stamp, STALE)
    short = ctypes.create_string_buffer(b"\xa5" * (len(changed[1]) - 1), len(changed[1]) - 1)
    sentinel = short.raw
    status, info, required = runtime.raw_snapshot(changed[0].stamp, short)
    require(status == SMALL and required == len(changed[1]) and metadata(info) == metadata(changed[0]) and short.raw == sentinel,
            "short snapshot buffer was overwritten or metadata changed")
    checks.append("two_phase_snapshot_stale_and_short_buffers_preserved")

    stale_request = request(2, initial[0].stamp, "history.undo")
    stale = runtime.submit(stale_request, STALE, REJECTED)
    require(outcome(runtime.submit(stale_request, STALE, REPLAYED)) == outcome(stale), "stale receipt was not retained")
    unchanged(runtime, changed, "stale request changed the document")
    runtime.submit(request(3, changed[0].stamp, "editor.gain.set", "c1 0.25"), OK, EXECUTED)
    committed = runtime.snapshot()
    # Rejected admissions also occupy receipts; filling the ring does not need
    # dozens of unrelated disk writes or consume the document History limit.
    sequence = 3
    for _ in range(RECEIPT_CAPACITY + 1):
        sequence += 1
        runtime.submit(request(sequence, committed[0].stamp, "doc.save"), UNSUPPORTED, REJECTED)
    runtime.submit(first_request, EXPIRED, REJECTED)
    unchanged(runtime, committed, "expired token executed the old node creation again")
    checks.append("stale_rejection_receipt_and_evicted_receipt_fail_closed")

    journal = check_root(runtime.data / "documents/history.txt")
    before_journal = journal.read_bytes()
    sequence += 1
    failed_request = request(sequence, committed[0].stamp, "editor.invert.add", "c1")
    kernel, lock = exclusive_file(journal)
    try:
        failed = runtime.submit(failed_request, FAILED, EXECUTED)
        require(failed.created_id == 0 and stamp(failed.stamp) == stamp(committed[0].stamp),
                "failed persistence published an ID or changed the revision")
        unchanged(runtime, committed, "exclusive journal lock changed the published document")
    finally:
        kernel.CloseHandle(lock)
    require(journal.read_bytes() == before_journal, "failed persistence changed the journal")
    require(outcome(runtime.submit(failed_request, FAILED, REPLAYED)) == outcome(failed), "unlocked duplicate did not replay failure")
    unchanged(runtime, committed, "retrying a failed token executed it after unlock")
    require(journal.read_bytes() == before_journal, "cached failure retry wrote the journal")
    retry = runtime.submit(request(sequence + 1, committed[0].stamp, "editor.invert.add", "c1"), OK, EXECUTED)
    latest = runtime.snapshot()
    require(set(node_ids(latest[1])) - set(node_ids(committed[1])) == {retry.created_id}
            and latest[0].stamp.revision == committed[0].stamp.revision + 1 and journal.read_bytes() != before_journal,
            "new sequence did not recover cleanly after unlock")
    checks.append("locked_journal_failure_cached_same_token_new_sequence_recovers")
    return first_request, latest


def concurrent(runtime, checks):
    initial = runtime.snapshot()
    shared = request(1, initial[0].stamp, "editor.invert.add", "c1", client=(2, 1))

    def wave(values):
        barrier = threading.Barrier(len(values), timeout=20)

        def submit(value):
            barrier.wait()
            return runtime.submit(value)

        with ThreadPoolExecutor(max_workers=len(values)) as pool:
            return list(pool.map(submit, values))

    results = wave([shared] * 8)
    require(all(value.status == OK for value in results)
            and sum(value.disposition == EXECUTED for value in results) == 1
            and sum(value.disposition == REPLAYED for value in results) == 7
            and len({outcome(value) for value in results}) == 1,
            "concurrent identical submissions did not execute exactly once")
    changed = runtime.snapshot()
    require(changed[0].stamp.revision == initial[0].stamp.revision + 1
            and set(node_ids(changed[1])) - set(node_ids(initial[1])) == {results[0].created_id},
            "concurrent duplicate submissions published multiple edits")
    values = [request(1, changed[0].stamp, "editor.invert.add", "c1", client=(3, index + 1)) for index in range(8)]
    results = wave(values)
    require(sum(value.status == OK and value.disposition == EXECUTED for value in results) == 1
            and sum(value.status == STALE and value.disposition == REJECTED for value in results) == 7,
            "same-version concurrent writers did not serialize into one commit and seven stale rejections")
    latest = runtime.snapshot()
    winner = next(value for value in results if value.status == OK)
    require(latest[0].stamp.revision == changed[0].stamp.revision + 1
            and set(node_ids(latest[1])) - set(node_ids(changed[1])) == {winner.created_id},
            "concurrent admission changed more than one document revision")
    checks.append("concurrent_duplicate_once_and_same_version_writers_one_winner")


def argument_presence(runtime, checks):
    for client in ((4, 1), (4, 2)):
        initial = runtime.snapshot()
        explicit_empty = request(1, initial[0].stamp, "editor.invert.add", "", client=client)
        failed = runtime.submit(explicit_empty, 3, EXECUTED)
        require(failed.created_id == 0 and stamp(failed.stamp) == stamp(initial[0].stamp),
                "explicit empty argument fell back to the default output and created a node")
        require(outcome(runtime.submit(explicit_empty, 3, REPLAYED)) == outcome(failed),
                "explicit empty argument did not retain its failure receipt")
        runtime.submit(request(1, initial[0].stamp, "editor.invert.add", client=client), CONFLICT, REJECTED)
        unchanged(runtime, initial, "argument-presence conflict changed the document")
        created = runtime.submit(request(2, initial[0].stamp, "editor.invert.add", client=client), OK, EXECUTED)
        latest = runtime.snapshot()
        previous_output = next(line.split(b"=", 1)[1] for line in initial[1].splitlines() if line.startswith(b"output="))
        expected_line = f"c{created.created_id}=invert{{ in:{previous_output.decode('ascii')} }}".encode("ascii")
        require(set(node_ids(latest[1])) - set(node_ids(initial[1])) == {created.created_id}
                and latest[0].stamp.revision == initial[0].stamp.revision + 1 and expected_line in latest[1].splitlines(),
                "new sequence with an absent argument did not create exactly one node on the default output")
    checks.append("two_clients_distinguish_empty_argument_from_absent_and_hash_presence")


def main():
    host_api = identity()["host_api"]
    require(host_api >= 8, f"workspace probe requires API v1 (host ABI8+), product declares {host_api}")
    resource = (OUTPUT / "portable/runtime").resolve()
    manifest = json.loads((resource / "runtime-pack.json").read_text(encoding="utf-8"))
    require(manifest["host_api"] == host_api, "distributed Pack and product host ABI disagree")
    root = claim(default_root("workspace"))
    before_pack = hashes(resource)
    report = {"format": "cutrans-workspace-evidence/1", "result": "failed", "host_api": host_api, "workspace_api": 1,
              "runtime_root": str(resource), "runtime_files": before_pack, "checks": [],
              "system_registration": "not performed", "real_user_data": "untouched"}
    try:
        library = ctypes.WinDLL(str(resource / "cutrans_vm_runtime.dll"))
        configure(library)
        require(library.cutrans_vm_abi_version() == host_api, "loaded DLL has the wrong host ABI")
        runtime = Runtime(library, resource, root / "persistent data", host_api)
        try:
            old_request, latest = sequential(runtime, report["checks"])
            (root / "committed.cut").write_bytes(latest[1])
            report["before_restart_stamp"] = stamp(latest[0].stamp)
        finally:
            runtime.close()
        runtime = Runtime(library, resource, root / "persistent data", host_api)
        try:
            restored = runtime.snapshot()
            require(stamp(restored[0].stamp)[:2] != stamp(latest[0].stamp)[:2] and restored[0].stamp.revision == 1,
                    "Runtime recreation reused its old epoch or persisted a volatile revision")
            require(restored[1] == latest[1] and restored[0].fingerprint == latest[0].fingerprint
                    and restored[0].node_id_high_water == latest[0].node_id_high_water,
                    "new epoch did not restore the committed canonical document and node high-water mark")
            runtime.submit(old_request, WRONG_EPOCH, REJECTED)
            rejected_snapshot(runtime, latest[0].stamp, WRONG_EPOCH)
            unchanged(runtime, restored, "old-epoch request changed the restored document")
            report["after_restart_stamp"] = stamp(restored[0].stamp)
            report["checks"].append("same_data_runtime_restart_new_epoch_rejects_old_requests_and_snapshots")
        finally:
            runtime.close()
        runtime = Runtime(library, resource, root / "concurrent data", host_api)
        try:
            concurrent(runtime, report["checks"])
        finally:
            runtime.close()
        runtime = Runtime(library, resource, root / "argument presence data", host_api)
        try:
            argument_presence(runtime, report["checks"])
        finally:
            runtime.close()
        require(hashes(resource) == before_pack, "workspace verification modified the distributed Runtime Pack")
        report["result"] = "passed"
    except BaseException as error:
        report["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        report["runtime_pack_unchanged"] = hashes(resource) == before_pack
        check_root(root / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        retain(root)
    print(f"CUTRANS_WORKSPACE_OK checks={len(report['checks'])} abi={host_api} dedupe=once snapshot=versioned pack_unchanged=1 evidence={root}")


if __name__ == "__main__":
    main()
