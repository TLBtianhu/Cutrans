"""Probe durable PNG jobs against the real DLL and autonomous, Shell-free Host."""
from __future__ import annotations

import argparse
import binascii
import ctypes
import hashlib
import json
import os
import shutil
import struct
import sys
import time
import zlib
from pathlib import Path

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from product import identity
from verification_paths import check_root, claim, default_root, retain
from verify_edit_commit import exclusive_file
from verify_host import invoke, run
from verify_input import ByteSlice, hashes, string_slice
from verify_workspace import Outcome, Runtime, configure as workspace_configure, request, stamp
from verify_workspace_rpc import MAX_PAYLOAD, Pipe, Workspace

OK, ACCEPTED, FAILED, SMALL = 0, 1, 8, 15
JOBS_READ = 24
TINY = "version=2\nresolution=7x5\nfps=30\nnodes:\nc0=testsrc{}\nc1=gain{ in:c0,value:0.2 }\noutput=c1\n"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def digest_text(value):
    # Zig's fixed byte array and a string both carry the same 64 ASCII bytes.
    text = bytes(value).decode("ascii") if isinstance(value, list) else value
    require(isinstance(text, str) and len(text) == 64 and all(c in "0123456789abcdef" for c in text),
            "invalid output digest in the job projection")
    return text


def png(path, width=7, height=5):
    """Decode the tested RGBA8 PNG with only the Python standard library."""
    raw = path.read_bytes()
    require(raw[:8] == b"\x89PNG\r\n\x1a\n", "export is not a PNG")
    position, compressed, header, ended = 8, bytearray(), None, False
    while position < len(raw):
        require(position + 12 <= len(raw), "truncated PNG chunk")
        length = struct.unpack_from(">I", raw, position)[0]
        kind = raw[position + 4:position + 8]
        body = raw[position + 8:position + 8 + length]
        require(position + 12 + length <= len(raw), "truncated PNG payload")
        expected_crc = struct.unpack_from(">I", raw, position + 8 + length)[0]
        require(binascii.crc32(kind + body) & 0xFFFFFFFF == expected_crc, "PNG CRC mismatch")
        if kind == b"IHDR":
            require(header is None and length == 13, "invalid PNG header")
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            compressed.extend(body)
        elif kind == b"IEND":
            ended = True
            position += 12 + length
            break
        position += 12 + length
    require(ended and position == len(raw) and header == (width, height, 8, 6, 0, 0, 0),
            "PNG dimensions, RGBA8 format, or completion are wrong")
    filtered = zlib.decompress(compressed)
    stride = width * 4
    require(len(filtered) == height * (stride + 1), "PNG scanline size mismatch")
    previous, pixels = bytearray(stride), bytearray()
    for y in range(height):
        at = y * (stride + 1)
        kind = filtered[at]
        require(kind <= 4, "invalid PNG filter")
        row = bytearray(filtered[at + 1:at + 1 + stride])
        for x in range(stride):
            left, above, upper = (row[x - 4] if x >= 4 else 0), previous[x], (previous[x - 4] if x >= 4 else 0)
            if kind == 0:
                predictor = 0
            elif kind == 1:
                predictor = left
            elif kind == 2:
                predictor = above
            elif kind == 3:
                predictor = (left + above) // 2
            else:
                p = left + above - upper
                distances = abs(p - left), abs(p - above), abs(p - upper)
                predictor = (left, above, upper)[distances.index(min(distances))]
            row[x] = (row[x] + predictor) & 255
        pixels.extend(row)
        previous = row
    return {"sha256": hashlib.sha256(raw).hexdigest(), "size": len(raw), "width": width, "height": height,
            "first_pixel": list(pixels[:4]), "pixels_sha256": hashlib.sha256(pixels).hexdigest()}


def tiny_png(pixel):
    """A valid, deterministic owned 1x1 source; no third-party encoder required."""
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0" + bytes(pixel))) + chunk(b"IEND", b""))


def validate_page(page, after):
    require(page.get("format") == "cutrans-jobs-page/1" and page.get("after") == after,
            "wrong jobs page format or cursor")
    items = page.get("items")
    require(isinstance(items, list) and len(items) <= 32, "jobs page is not bounded")
    ids = [item["id"] for item in items]
    require(ids == sorted(set(ids)) and all(value > after for value in ids), "job page IDs are not ascending")
    require(page["next_after"] == (ids[-1] if ids else after), "jobs cursor skipped an item")
    for item in items:
        require(item["attempt"] == 1 and item["state"] in {"queued", "running", "succeeded", "failed", "cancelled", "interrupted"},
                "invalid B1 job attempt/state")
        require(isinstance(item["origin"], dict) and item["origin"]["revision"] > 0, "job lost its origin version")
        digest_text(item["output_sha256"])
    return page


class Native(Runtime):
    def __init__(self, library, resource, data, evidence):
        super().__init__(library, resource, data, identity()["host_api"])
        self.sequence = 0
        self.evidence = evidence

    def submit_edit(self, name, arg=None, expected_status=OK):
        info, _ = self.snapshot()
        self.sequence += 1
        value = request(self.sequence, info.stamp, name, arg, client=(0xB101, 0xB102))
        result = Outcome()
        transport = self.api.submit(self.api.context, ctypes.byref(value), ctypes.byref(result))
        require(transport == OK, f"{name}: unknown transport result {transport}")
        require(result.struct_size == ctypes.sizeof(Outcome) and result.api_version == 1
                and result.sequence == self.sequence and result.status == expected_status,
                f"{name}: status={result.status}, expected={expected_status}")
        require((result.task_id != 0) == (expected_status == ACCEPTED), "job admission leaked or omitted its task ID")
        self.evidence.setdefault("native_requests", []).append({"data": str(self.data), "name": name, "arg": arg,
            "sequence": self.sequence, "expected": stamp(info.stamp), "status": result.status,
            "task_id": result.task_id, "disposition": result.disposition})
        return result

    def legacy(self, name, arg=None, expected=OK):
        name_value, name_storage = string_slice(name)
        arg_value, arg_storage = string_slice(arg) if arg is not None else (ByteSlice(), None)
        task_id = ctypes.c_uint64(999)
        actual = self.library.cutrans_vm_command_result(self.handle, name_value, arg_value, ctypes.byref(task_id))
        require(actual == expected and task_id.value == 0, f"legacy {name}: status={actual}, task={task_id.value}")

    def page(self, after=0):
        for _ in range(4):
            required = ctypes.c_size_t()
            status = self.library.cutrans_vm_jobs_read(self.handle, after, None, 0, ctypes.byref(required))
            require(status == SMALL and 0 < required.value <= 256 * 1024, f"jobs size query failed: {status}")
            buffer = ctypes.create_string_buffer(required.value)
            status = self.library.cutrans_vm_jobs_read(self.handle, after, buffer, len(buffer), ctypes.byref(required))
            if status == SMALL:
                continue
            require(status == OK and required.value <= len(buffer), f"jobs read failed: {status}")
            return validate_page(json.loads(buffer.raw[:required.value]), after)
        raise RuntimeError("jobs page kept changing size")

    def all_jobs(self):
        return collect_pages(self.page)

    def drain(self):
        for _ in range(64):
            pending = ctypes.c_uint32(999)
            status = self.library.cutrans_vm_jobs_pump(self.handle, ctypes.byref(pending))
            require(status == OK and pending.value in (0, 1), f"jobs pump failed: status={status}, pending={pending.value}")
            if pending.value == 0:
                return
        raise RuntimeError("manual jobs pump did not drain its bounded queue")


def collect_pages(read):
    after, items = 0, []
    for _ in range(128):
        page = read(after)
        if not page["items"]:
            return items
        items.extend(page["items"])
        after = page["next_after"]
    raise RuntimeError("job pagination did not terminate")


def configure(library):
    workspace_configure(library)
    library.cutrans_vm_command_result.argtypes = [ctypes.c_void_p, ByteSlice, ByteSlice, ctypes.POINTER(ctypes.c_uint64)]
    library.cutrans_vm_command_result.restype = ctypes.c_int32
    library.cutrans_vm_grant_external.argtypes = [ctypes.c_void_p, ByteSlice, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint64)]
    library.cutrans_vm_grant_external.restype = ctypes.c_int32
    library.cutrans_vm_jobs_pump.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    library.cutrans_vm_jobs_pump.restype = ctypes.c_int32
    library.cutrans_vm_jobs_read.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t,
                                            ctypes.POINTER(ctypes.c_size_t)]
    library.cutrans_vm_jobs_read.restype = ctypes.c_int32


def tiny_document(runtime, path):
    path.write_text(TINY, encoding="utf-8")
    value, storage = string_slice(str(path))
    grant = ctypes.c_uint64()
    require(runtime.library.cutrans_vm_grant_external(runtime.handle, value, 0, ctypes.byref(grant)) == OK and grant.value,
            "could not grant read-only access to the synthetic document")
    runtime.submit_edit("doc.open", f"external://{grant.value}")


def assert_output(item, path, first_pixel):
    result = png(path)
    require(result["first_pixel"] == list(first_pixel), "export did not use its accepted document version")
    require(item["state"] == "succeeded" and item["phase"] == "succeeded" and not item["persistence_pending"],
            "output exists without a durable successful job record")
    require(digest_text(item["output_sha256"]) == result["sha256"] and item["output_size"] == result["size"],
            "job receipt digest/size does not describe the actual output")
    return result


def native_cases(library, resource, root, evidence):
    checks = evidence["checks"]
    runtime = Native(library, resource, root / "versioned data", evidence)
    try:
        tiny_document(runtime, root / "tiny.cut")
        first_info, _ = runtime.snapshot()
        first = runtime.submit_edit("editor.export.png", "session://exports/version-one.png", ACCEPTED).task_id
        runtime.submit_edit("editor.gain.set", "c1 0.8")
        second_info, _ = runtime.snapshot()
        second = runtime.submit_edit("editor.export.png", "session://exports/version-two.png", ACCEPTED).task_id
        runtime.submit_edit("editor.gain.set", "c1 0.5")
        current = runtime.snapshot()[0]
        require(first_info.stamp.revision < second_info.stamp.revision < current.stamp.revision, "fixture did not create three revisions")
        before = runtime.all_jobs()
        require([row["state"] for row in before] == ["queued", "queued"], "embedded Runtime auto-executed a job")
        runtime.drain()
        rows = {row["id"]: row for row in runtime.all_jobs()}
        one = assert_output(rows[first], runtime.data / "exports/version-one.png", (6, 19, 38, 255))
        two = assert_output(rows[second], runtime.data / "exports/version-two.png", (26, 77, 153, 255))
        require(one["pixels_sha256"] != two["pixels_sha256"] and rows[first]["source_fingerprint"] == first_info.fingerprint
                and rows[second]["source_fingerprint"] == second_info.fingerprint, "job version provenance was not preserved")
        evidence["versioned_outputs"] = {"jobs": list(rows.values()), "one": one, "two": two}
        checks.append("two_accepted_versions_export_independently_after_current_document_changes")
        pending = []
        for index in range(8):
            pending.append(runtime.submit_edit("editor.export.png", f"session://exports/queue-{index}.png", ACCEPTED).task_id)
        runtime.submit_edit("editor.export.png", "session://exports/ninth.png", 7)
        runtime.legacy("task.cancel", str(pending[-1]))
        runtime.submit_edit("editor.export.png", "session://exports/queue-0.png", 5)
        runtime.drain()
        rows = {row["id"]: row for row in runtime.all_jobs()}
        require(rows[pending[-1]]["state"] == "cancelled" and not (runtime.data / "exports/queue-7.png").exists()
                and not (runtime.data / "exports/ninth.png").exists(), "cancelled/backpressured work produced output")
        checks.append("eight_active_jobs_backpressure_target_conflict_and_durable_queued_cancel")
        for index in range(42):
            runtime.submit_edit("editor.export.png", f"session://exports/archive-{index}.png", ACCEPTED)
            runtime.drain()
        archived = runtime.all_jobs()
        require(len(archived) == 52 and archived[0]["id"] == first and archived[-1]["id"] > 40
                and all(a["id"] < b["id"] for a, b in zip(archived, archived[1:])), "terminal cache became a lifetime limit or old archive IDs were lost")
        evidence["archive"] = archived
        checks.append("more_than_forty_terminal_jobs_remain_admissible_and_old_ids_paginate")
    finally:
        runtime.close()

    runtime = Native(library, resource, root / "admission failure data", evidence)
    try:
        tiny_document(runtime, root / "admission.cut")
        journal = runtime.data / "tasks/journal.txt"
        old_journal = journal.read_bytes() if journal.exists() else None
        blocked = check_root(runtime.data / "tasks/jobs")
        require(not blocked.exists(), "admission blocker is not a new owned fixture")
        blocked.parent.mkdir(parents=True, exist_ok=True)
        blocked.write_bytes(b"synthetic admission blocker; preserve on failure")
        runtime.submit_edit("editor.export.png", "session://exports/refused.png", FAILED)
        require(blocked.read_bytes() == b"synthetic admission blocker; preserve on failure"
                and (journal.read_bytes() if journal.exists() else None) == old_journal
                and not (runtime.data / "exports/refused.png").exists(), "failed admission published work or changed the old Task projection")
        blocked.unlink()  # Exact file created above, beneath this claimed verification case.
        admitted = runtime.submit_edit("editor.export.png", "session://exports/retry.png", ACCEPTED)
        require(admitted.task_id == 1, "failed admission consumed/published a Task ID")
        runtime.drain()
        checks.append("admission_record_failure_never_publishes_task_or_acceptance")
    finally:
        runtime.close()

    runtime = Native(library, resource, root / "locked output data", evidence)
    try:
        tiny_document(runtime, root / "locked.cut")
        target = check_root(runtime.data / "exports/locked.png")
        target.parent.mkdir(parents=True, exist_ok=True)
        sentinel = b"real old target sentinel; must not be truncated"
        target.write_bytes(sentinel)
        job = runtime.submit_edit("editor.export.png", "session://exports/locked.png", ACCEPTED).task_id
        kernel, handle = exclusive_file(target)
        try:
            runtime.drain()
        finally:
            kernel.CloseHandle(handle)
        row = next(row for row in runtime.all_jobs() if row["id"] == job)
        require(row["state"] == "failed" and row["phase"] == "failed" and row["error_text"] and target.read_bytes() == sentinel,
                "locked output did not fail explicitly while preserving old bytes")
        runtime.drain()
        require(target.read_bytes() == sentinel and list(target.parent.iterdir()) == [target], "failed job retried output or retained a temporary PNG")
        evidence["locked_output"] = row
        checks.append("exclusive_output_lock_preserves_old_sentinel_without_automatic_rerender")
    finally:
        runtime.close()

    data = root / "restart data"
    runtime = Native(library, resource, data, evidence)
    try:
        tiny_document(runtime, root / "restart.cut")
        job = runtime.submit_edit("editor.export.png", "session://exports/interrupted.png", ACCEPTED).task_id
        before = next(row for row in runtime.all_jobs() if row["id"] == job)
        runtime.submit_edit("editor.gain.set", "c1 0.5")
        current_fingerprint = runtime.snapshot()[0].fingerprint
    finally:
        runtime.close()
    runtime = Native(library, resource, data, evidence)
    try:
        after = next(row for row in runtime.all_jobs() if row["id"] == job)
        require(after["state"] == "interrupted" and after["error_text"] and after["origin"] == before["origin"]
                and after["source_fingerprint"] == before["source_fingerprint"] and runtime.snapshot()[0].fingerprint == current_fingerprint,
                "restart lost the saved job specification or current document")
        runtime.drain()
        require(not (data / "exports/interrupted.png").exists(), "recovered interrupted job auto-executed")
        spec = json.loads((data / "tasks/jobs" / f"{job:020d}.json").read_text(encoding="utf-8"))
        require("value:0.2" in spec["job"]["document"] and spec["task"]["state"] == "interrupted", "durable immutable document specification was lost")
        evidence["restarted_job"] = after
        checks.append("runtime_recreation_preserves_spec_explains_interruption_and_never_autoexecutes")
    finally:
        runtime.close()

    copied_resource = check_root(root / "source drift Runtime")
    shutil.copytree(resource, copied_resource)
    source = check_root(copied_resource / "assets/examples/b1-source.png")
    source.write_bytes(tiny_png((12, 34, 56, 255)))
    require(png(source, 1, 1)["first_pixel"] == [12, 34, 56, 255], "synthetic source fixture is invalid")
    source_hash = sha256(source)
    runtime = Native(library, copied_resource, root / "source drift data", evidence)
    try:
        runtime.submit_edit("editor.image.open", "pack://assets/examples/b1-source.png")
        job = runtime.submit_edit("editor.export.png", "session://exports/stale-source.png", ACCEPTED).task_id
        record = json.loads((runtime.data / "tasks/jobs" / f"{job:020d}.json").read_text(encoding="utf-8"))
        require(source_hash in record["job"]["document"], "admitted job did not freeze the Source content version")
        source.write_bytes(tiny_png((200, 40, 80, 255)))
        require(sha256(source) != source_hash, "Source drift fixture did not change the bytes")
        runtime.drain()
        row = next(row for row in runtime.all_jobs() if row["id"] == job)
        require(row["state"] == "failed" and row["phase"] == "failed" and "Mismatch" in row["error_text"]
                and not (runtime.data / "exports/stale-source.png").exists(),
                "changed Source silently replaced the accepted content version or produced an output")
        evidence["source_drift"] = {"accepted_source_sha256": source_hash, "changed_source_sha256": sha256(source), "job": row}
        checks.append("accepted_Source_hash_rejects_later_pack_byte_drift_without_output")
    finally:
        runtime.close()


def pipe_jobs(wire, after=0):
    if after == 0:
        status, payload = wire.rpc(JOBS_READ, b"")
    else:
        connection = Pipe(wire.endpoint)
        header = struct.pack("<8sIIQII", b"CUTRSH2\0", JOBS_READ, 0, after, 0, 0)
        frame = {"kind": JOBS_READ, "request_header": header.hex(), "request_payload": ""}
        wire.frames.append(frame)
        try:
            connection.write(header)
            response = connection.read(32)
            frame["response_header"] = response.hex()
            magic, kind, status, value, length, reserved = struct.unpack("<8sIiQII", response)
            require(magic == b"CUTRSR2\0" and kind == JOBS_READ and value == reserved == 0 and length <= MAX_PAYLOAD,
                    "invalid paged jobs pipe reply")
            payload = connection.read(length) if length else b""
            frame["response_payload"] = payload.hex()
        finally:
            connection.close()
    require(status == OK and payload, f"Host jobs query failed: {status}")
    return validate_page(json.loads(payload), after)


def host_case(console, root, evidence):
    data = root / "autonomous Host data"
    stopped = True
    try:
        _, before = invoke(console, "status", data, "portable")
        require(before["state"] == "unreachable", "owned Host case already has an active instance")
        _, started = invoke(console, "start", data, "portable")
        stopped = False
        require(started["state"] == "running", "isolated Host did not start")
        wire = Workspace(data, evidence)
        initial = wire.snapshot()
        client = (0xB1A0, 0xB1A1)
        fixture = check_root(data / "fixtures/tiny.cut")
        fixture.parent.mkdir(parents=True, exist_ok=True)
        fixture.write_text(TINY, encoding="utf-8")
        opened = wire.submit(wire.request(client, 1, initial["stamp"], "doc.open", "session://fixtures/tiny.cut"))
        require(opened["status"] == OK, "Host did not accept the tiny synthetic document")
        accepted = wire.submit(wire.request(client, 2, opened["stamp"], "editor.export.png", "session://exports/autonomous.png"))
        require(accepted["status"] == ACCEPTED and accepted["task_id"], "Host did not durably admit the export")
        target = data / "exports/autonomous.png"
        frames_before, started_wait = len(wire.frames), time.monotonic()
        deadline = started_wait + 20
        # No pump, state polling, or jobs RPC is sent while the Host must work.
        while not target.is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        require(target.is_file() and len(wire.frames) == frames_before, "Host required a Shell/pump/poll to produce the output")
        file_wait_seconds = time.monotonic() - started_wait
        rows = collect_pages(lambda after: pipe_jobs(wire, after))
        row = next(row for row in rows if row["id"] == accepted["task_id"])
        output = assert_output(row, target, (6, 19, 38, 255))
        text = run([str(console), "jobs", "--mode=portable", f"--data={data}"])
        cli = next((json.loads(line.split(" ", 1)[1]) for line in text.splitlines() if line.startswith("CUTRANS_VM_JOBS_JSON ")), None)
        require(cli is not None and any(item["id"] == row["id"] and item["state"] == "succeeded" for item in cli["items"]),
                "real CLI jobs does not expose the autonomous outcome")
        _, final = invoke(console, "stop", data, "portable")
        require(final["state"] == "stopped", "Host did not stop cleanly")
        stopped = True
        _, restarted = invoke(console, "start", data, "portable")
        stopped = False
        require(restarted["state"] == "running", "Host did not restart")
        recovered = next(item for item in collect_pages(lambda after: pipe_jobs(wire, after)) if item["id"] == row["id"])
        require(recovered == row and sha256(target) == output["sha256"], "Host restart changed the durable completed Job or output")
        evidence["autonomous_host"] = {"started": started, "accepted": accepted, "job": row, "output": output,
            "file_wait_seconds": file_wait_seconds, "rpc_frames_during_file_wait": 0,
            "shell_attached": False, "restarted_job": recovered}
        evidence["checks"].append("real_Host_without_Shell_exports_without_pump_or_poll_and_CLI_restart_preserves_job")
    finally:
        if not stopped:
            _, cleanup = invoke(console, "stop", data, "portable")
            require(cleanup["state"] == "stopped", "owned autonomous Host cleanup failed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("jobs"))
    args = parser.parse_args()
    require(os.name == "nt", "real DLL, file sharing and Host verification require Windows")
    root = claim(args.root)
    portable = (OUTPUT / "portable").resolve()
    resource = portable / "runtime"
    before = hashes(portable)
    evidence = {"format": "cutrans-jobs-verification/1", "root": str(root), "artifact_hashes": before,
                "checks": [], "passed": False,
                "limits": ["B1 has one serial synchronous PNG attempt; running cancellation/parallel rendering are not tested",
                           "This does not test a GUI disconnect/reconnect, old-version byte retention, or system installation"]}
    try:
        library = ctypes.WinDLL(str(resource / "cutrans_vm_runtime.dll"))
        configure(library)
        require(library.cutrans_vm_abi_version() == identity()["host_api"], "tested Runtime ABI differs from product identity")
        native_cases(library, resource, root, evidence)
        host_case(portable / "cutrans_vm.exe", root, evidence)
        require(hashes(portable) == before and not (portable / "data").exists(), "verification modified the tested portable artifact")
        evidence["passed"] = True
        print(f"CUTRANS_JOBS_VERIFY_OK checks={len(evidence['checks'])} versions=2 active_limit=8 archive=52 cancel=queued output_atomic=1 recovery=interrupted autonomous_host=1 evidence={root}")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        evidence["artifact_hashes_after"] = hashes(portable)
        (root / "report.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)


if __name__ == "__main__":
    main()
