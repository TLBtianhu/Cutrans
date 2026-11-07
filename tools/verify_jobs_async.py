"""Verify B2 owned-worker, cancellation and explicit retries on real DLL/Host artifacts.

Timing is observation, never an injected delay: a missed running window is
reported as inconclusive and cannot make this verification pass. Deterministic
owner-lock/Source barriers belong to the source tests, not the product ABI.
Run tools/verify_jobs.py separately for the complete B1 regression.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import re
import shutil
import struct
import sys
import threading
import time
import zlib
from pathlib import Path

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from product import identity
from verification_paths import check_root, claim, default_root, retain
from verify_host import invoke, run
from verify_input import ByteSlice, hashes, string_slice
from verify_jobs import (ACCEPTED, JOBS_READ, OK, SMALL, TINY, Native, collect_pages,
                         configure as jobs_configure, digest_text, png, require,
                         sha256, tiny_png)
from verify_workspace import Outcome, request, stamp
from verify_workspace_rpc import MAX_PAYLOAD, Pipe, Workspace

INVALID_ARGUMENTS, INVALID_STATE = 3, 5
BIG = TINY.replace("resolution=7x5", "resolution=4096x4096")
TERMINAL = {"succeeded", "failed", "cancelled", "interrupted"}


def validate_page(page, after):
    require(page.get("format") == "cutrans-jobs-page/1" and page.get("after") == after,
            "wrong jobs page format or cursor")
    items = page.get("items")
    require(isinstance(items, list) and len(items) <= 32, "unbounded jobs page")
    ids = [item["id"] for item in items]
    require(ids == sorted(set(ids)) and all(value > after for value in ids), "unordered job identities")
    require(page["next_after"] == (ids[-1] if ids else after), "jobs cursor skipped an item")
    require(isinstance(page["active_count"], int) and 0 <= page["active_count"] <= 8,
            "active_count is not the bounded queued-plus-running count")
    for item in items:
        require(item["state"] in TERMINAL | {"queued", "running"} and item["attempt"] >= 1,
                "invalid attempt/state in B2 job projection")
        require(isinstance(item["cancel_requested"], bool), "cancellation intent missing")
        require((item["attempt"] == 1 and item["retry_of"] is None) or
                (item["attempt"] > 1 and isinstance(item["retry_of"], int) and 0 < item["retry_of"] < item["id"]),
                "invalid attempt lineage")
        require(item["origin"]["revision"] > 0, "job lost its origin revision")
        digest_text(item["output_sha256"])
    return page


class AsyncNative(Native):
    def page(self, after=0):
        for _ in range(8):
            required = ctypes.c_size_t()
            status = self.library.cutrans_vm_jobs_read(self.handle, after, None, 0, ctypes.byref(required))
            require(status == SMALL and 0 < required.value <= 256 * 1024, f"jobs size query failed: {status}")
            buffer = ctypes.create_string_buffer(required.value)
            status = self.library.cutrans_vm_jobs_read(self.handle, after, buffer, len(buffer), ctypes.byref(required))
            if status == SMALL:
                continue
            require(status == OK and required.value <= len(buffer), f"jobs read failed: {status}")
            return validate_page(json.loads(buffer.raw[:required.value]), after)
        raise RuntimeError("jobs page did not stabilize")

    def exact_submit(self, value, expected, disposition=None):
        result = Outcome()
        transport = self.api.submit(self.api.context, ctypes.byref(value), ctypes.byref(result))
        require(transport == OK, f"unknown Workspace transport result {transport}")
        require(result.struct_size == ctypes.sizeof(Outcome) and result.api_version == 1
                and result.sequence == value.sequence and result.status == expected,
                f"Workspace result={result.status}, expected={expected}")
        require((result.task_id != 0) == (expected == ACCEPTED), "bad task identity in Workspace result")
        if disposition is not None:
            require(result.disposition == disposition, "exact retry did not replay the retained receipt")
        self.evidence.setdefault("exact_requests", []).append({"data": str(self.data), "sequence": value.sequence,
            "expected": stamp(value.expected), "status": result.status, "disposition": result.disposition,
            "task_id": result.task_id})
        return result

    def legacy_status(self, name, arg=None):
        name_value, name_storage = string_slice(name)
        arg_value, arg_storage = string_slice(arg) if arg is not None else (ByteSlice(), None)
        task = ctypes.c_uint64(999)
        status = self.library.cutrans_vm_command_result(self.handle, name_value, arg_value, ctypes.byref(task))
        require(task.value == 0, "synchronous legacy operation published a task")
        return status

    def grant(self, path, writable=True):
        value, storage = string_slice(str(path))
        grant = ctypes.c_uint64()
        status = self.library.cutrans_vm_grant_external(self.handle, value, int(writable), ctypes.byref(grant))
        require(status == OK and grant.value > 0, f"synthetic external grant failed: {status}")
        return grant.value


def configure(library):
    jobs_configure(library)
    library.cutrans_vm_frame_pump.argtypes = [ctypes.c_void_p]
    library.cutrans_vm_frame_pump.restype = ctypes.c_int32


def open_document(runtime, text=TINY):
    fixture = check_root(runtime.data / "fixtures/document.cut")
    fixture.parent.mkdir(parents=True, exist_ok=True)
    fixture.write_text(text, encoding="utf-8")
    runtime.submit_edit("doc.open", "session://fixtures/document.cut")


def job(runtime, identity):
    return next(item for item in runtime.all_jobs() if item["id"] == identity)


def record(runtime, identity):
    return json.loads((runtime.data / "tasks/jobs" / f"{identity:020d}.json").read_text(encoding="utf-8"))


def assert_output(item, path, first_pixel):
    output = png(path)
    require(output["first_pixel"] == list(first_pixel), "retry used the current input instead of the original input")
    require(item["state"] == item["phase"] == "succeeded" and not item["persistence_pending"],
            "output has no durable successful outcome")
    require(digest_text(item["output_sha256"]) == output["sha256"] and item["output_size"] == output["size"],
            "actual output differs from its durable digest/size")
    return output


class Pump:
    """A real ABI call on a Python thread; ctypes releases the GIL."""
    def __init__(self, runtime):
        self.runtime, self.result, self.error = runtime, None, None
        self.started = time.monotonic()
        self.finished = None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        try:
            pending = ctypes.c_uint32(999)
            status = self.runtime.library.cutrans_vm_jobs_pump(self.runtime.handle, ctypes.byref(pending))
            self.result = {"status": status, "pending": pending.value}
        except BaseException as error:
            self.error = repr(error)
        finally:
            self.finished = time.monotonic()

    def start(self):
        self.thread.start()

    def finish(self):
        deadline = time.monotonic() + 120
        while self.thread.is_alive() and time.monotonic() < deadline:
            self.thread.join(0.05)
        require(not self.thread.is_alive(), "real jobs_pump did not return within 120 seconds; Runtime retained until process exit")
        require(self.error is None and self.result["status"] == OK and self.result["pending"] in (0, 1),
                f"real jobs_pump failed: {self.result}, {self.error}")

    def observe_running(self, identity):
        deadline = time.monotonic() + 20
        while self.thread.is_alive() and time.monotonic() < deadline:
            page = self.runtime.page()
            row = next((item for item in page["items"] if item["id"] == identity), None)
            if row and row["state"] == "running" and self.thread.is_alive():
                require(page["active_count"] >= 1, "active_count omitted the observed running worker")
                return row
            if row and row["state"] in TERMINAL:
                break
            # Yield only while discovering scheduling state; never stretch compute.
            threading.Event().wait(0.001)
        return None


def timed_action(pump, observations, name, action):
    before, started = pump.thread.is_alive(), time.monotonic()
    result = action()
    observation = {"action": name, "seconds": time.monotonic() - started,
                   "worker_alive_before": before, "worker_alive_after": pump.thread.is_alive()}
    observations.append(observation)
    return result


def queued_and_retry_case(library, resource, root, evidence):
    data = root / "durable retry data"
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        open_document(runtime)
        original = runtime.snapshot()[0]
        parent = runtime.submit_edit("editor.export.png", "session://exports/parent.png", ACCEPTED).task_id
        for _ in range(3):
            require(library.cutrans_vm_frame_pump(runtime.handle) == OK, "frame-only pump failed")
        page = runtime.page()
        require(page["active_count"] == 1 and job(runtime, parent)["state"] == "queued"
                and not (data / "exports/parent.png").exists(), "Shell frame stole queued export computation")
        runtime.legacy("task.cancel", str(parent))
        runtime.legacy("task.cancel", str(parent))
        cancelled = job(runtime, parent)
        require(cancelled["state"] == "cancelled" and cancelled["cancel_requested"]
                and record(runtime, parent)["job"]["cancel_requested"], "queued cancel was not durable/idempotent")
        runtime.submit_edit("editor.gain.set", "c1 0.8")
        evidence["checks"].append("frame_only_pump_preserves_queue_and_queued_cancel_is_durable_idempotent")
    finally:
        runtime.close()
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        old = job(runtime, parent)
        require(old == cancelled, "restart changed a durable cancelled job")
        current = runtime.snapshot()
        require(current[0].fingerprint != original.fingerprint, "retry fixture did not change the current input")
        value = request(1, current[0].stamp, "task.retry", f"{parent} session://exports/retry.png", client=(0xB201, 0xB202))
        first = runtime.exact_submit(value, ACCEPTED, 1)
        replay = runtime.exact_submit(value, ACCEPTED, 2)
        require(first.task_id == replay.task_id and len(runtime.all_jobs()) == 2,
                "identical retry token allocated a second attempt")
        admitted = job(runtime, first.task_id)
        require(admitted["attempt"] == 2 and admitted["retry_of"] == parent and admitted["origin"] == old["origin"]
                and admitted["source_fingerprint"] == old["source_fingerprint"]
                and admitted["document_fingerprint"] == old["document_fingerprint"], "retry changed immutable input/lineage")
        runtime.drain()
        row = job(runtime, first.task_id)
        output = assert_output(row, data / "exports/retry.png", (6, 19, 38, 255))
        require(job(runtime, parent) == old and "value:0.2" in record(runtime, first.task_id)["job"]["document"],
                "retry rewrote its old attempt or persisted the current gain")
        evidence["retry"] = {"parent": old, "child": row, "output": output}
        evidence["checks"].append("restart_retry_retains_original_revision_new_attempt_and_exact_token_receipt")
        runtime.legacy("task.cancel", str(parent))
        runtime.legacy("task.cancel", str(first.task_id), INVALID_STATE)
        require(job(runtime, first.task_id) == row and sha256(data / "exports/retry.png") == output["sha256"],
                "late cancellation altered a successful result")
        evidence["checks"].append("cancelled_terminal_cancel_repeats_and_successful_terminal_cancel_rejects")
    finally:
        runtime.close()


def concurrent_cancel_case(library, resource, root, evidence):
    runtime = AsyncNative(library, resource, root / "running cancellation data", evidence)
    pumping = None
    observations = []
    try:
        open_document(runtime, BIG)
        target = check_root(runtime.data / "exports/running.png")
        target.parent.mkdir(parents=True, exist_ok=True)
        sentinel = b"B2 owned old target; cancellation must preserve these exact bytes"
        target.write_bytes(sentinel)
        identity = runtime.submit_edit("editor.export.png", "session://exports/running.png", ACCEPTED).task_id
        pumping = Pump(runtime)
        pumping.start()
        running = pumping.observe_running(identity)
        if running is None:
            evidence["inconclusive"].append("4096x4096 worker completed before a running state could be observed")
        else:
            timed_action(pumping, observations, "managed_edit", lambda: runtime.submit_edit("editor.gain.set", "c1 0.8"))
            snapshot = timed_action(pumping, observations, "coherent_snapshot", runtime.snapshot)
            require("value:0.8" in snapshot[1].decode("utf-8"), "concurrent edit did not reach the coherent snapshot")
            status = timed_action(pumping, observations, "frame_only_pump", lambda: library.cutrans_vm_frame_pump(runtime.handle))
            require(status == OK, "frame-only pump failed during compute")
            cancel = timed_action(pumping, observations, "durable_cancel", lambda: runtime.legacy_status("task.cancel", str(identity)))
            if cancel == OK:
                require(record(runtime, identity)["job"]["cancel_requested"], "cancel acknowledgement preceded durable intent")
            elif pumping.thread.is_alive():
                raise RuntimeError(f"running cancellation unexpectedly rejected: {cancel}")
            if not all(item["worker_alive_before"] and item["worker_alive_after"] for item in observations):
                evidence["inconclusive"].append("4096x4096 running window ended before every concurrent operation returned")
            else:
                require(cancel == OK, "cancel did not succeed during the observed compute window")
                require(all(item["seconds"] < 5 for item in observations), "concurrent operation exceeded the five-second response bound")
                evidence["checks"].append("real_4k_worker_allows_edit_snapshot_frame_and_durable_cancel_before_compute_returns")
        pumping.finish()
        terminal = job(runtime, identity)
        if terminal["state"] == "cancelled":
            require(terminal["cancel_requested"] and target.read_bytes() == sentinel and not terminal["persistence_pending"],
                    "running cancellation lost durable intent or replaced old output")
            require(list(target.parent.iterdir()) == [target], "cancelled worker retained its temporary output")
            runtime.legacy("task.cancel", str(identity))
            evidence["checks"].append("real_running_cancellation_preserves_old_sentinel_and_cleans_its_candidate")
        elif running is not None and all(item["worker_alive_after"] for item in observations):
            raise RuntimeError(f"acknowledged live cancellation became {terminal['state']}")
        evidence["concurrency"] = {"running": running, "actions": observations, "terminal": terminal,
            "pump": pumping.result, "compute_seconds": pumping.finished - pumping.started,
            "fixture": "4096x4096 testsrc/gain, no injected delay"}
    finally:
        if pumping is None or not pumping.thread.is_alive():
            runtime.close()


def external_retry_case(library, resource, root, evidence):
    data = root / "external retry data"
    a, b = check_root(root / "external-A.png"), check_root(root / "external-B.png")
    a.write_bytes(b"A original sentinel")
    b.write_bytes(b"B original sentinel")
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        open_document(runtime)
        old_grant = runtime.grant(a)
        require(old_grant == 1, "fresh Runtime did not start its external namespace at 1")
        parent = runtime.submit_edit("editor.export.png", f"external://{old_grant}", ACCEPTED).task_id
        runtime.legacy("task.cancel", str(parent))
    finally:
        runtime.close()
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        reused = runtime.grant(b)
        require(reused == old_grant, "external grant reuse fixture did not reuse the numeric ID")
        runtime.submit_edit("task.retry", str(parent), INVALID_ARGUMENTS)
        runtime.submit_edit("task.retry", f"{parent} external://{reused}", INVALID_ARGUMENTS)
        require(len(runtime.all_jobs()) == 1 and a.read_bytes() == b"A original sentinel" and b.read_bytes() == b"B original sentinel",
                "unconfirmed external target reuse admitted work or changed output")
        evidence["checks"].append("reused_external_number_cannot_silently_redirect_retry_or_revive_old_authority")
        retarget = runtime.submit_edit("task.retry", f"{parent} --retarget external://{reused}", ACCEPTED).task_id
        runtime.drain()
        retarget_row = job(runtime, retarget)
        output_b = assert_output(retarget_row, b, (6, 19, 38, 255))
        require(a.read_bytes() == b"A original sentinel" and Path(retarget_row["target"]) == b,
                "explicit retarget modified the original physical target")
        grant_a = runtime.grant(a)
        require(grant_a != reused, "same-target retry fixture did not create fresh authority")
        matched = runtime.submit_edit("task.retry", f"{parent} external://{grant_a}", ACCEPTED).task_id
        runtime.drain()
        matched_row = job(runtime, matched)
        output_a = assert_output(matched_row, a, (6, 19, 38, 255))
        require(sha256(b) == output_b["sha256"] and matched_row["retry_of"] == retarget_row["retry_of"] == parent,
                "new matching authority changed another attempt or its lineage")
        evidence["external_retry"] = {"old_numeric_grant": old_grant, "reused_grant": reused, "matching_grant": grant_a,
            "retarget": retarget_row, "matching_target": matched_row, "output_a": output_a, "output_b": output_b}
        evidence["checks"].append("explicit_retarget_and_fresh_same_physical_target_grant_are_distinct_accepted_intents")
    finally:
        runtime.close()


def png_first_pixel(path, width, height):
    """Validate chunks and inspect one pixel without a slow Python 64 MiB pixel loop."""
    import binascii
    raw, position, compressed, ended = path.read_bytes(), 8, bytearray(), False
    require(raw[:8] == b"\x89PNG\r\n\x1a\n", "worker output is not PNG")
    header = None
    while position < len(raw):
        require(position + 12 <= len(raw), "truncated worker PNG chunk")
        length = struct.unpack_from(">I", raw, position)[0]
        kind, body = raw[position + 4:position + 8], raw[position + 8:position + 8 + length]
        require(position + length + 12 <= len(raw), "truncated worker PNG body")
        require(binascii.crc32(kind + body) & 0xFFFFFFFF == struct.unpack_from(">I", raw, position + 8 + length)[0],
                "worker PNG CRC mismatch")
        if kind == b"IHDR":
            require(header is None and length == 13, "invalid worker IHDR")
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            compressed.extend(body)
        elif kind == b"IEND":
            ended = True
            position += 12 + length
            break
        position += 12 + length
    require(ended and position == len(raw) and header == (width, height, 8, 6, 0, 0, 0), "wrong worker PNG dimensions/format")
    first = zlib.decompressobj().decompress(compressed, max_length=5)
    require(len(first) == 5 and first[0] <= 4, "invalid first worker PNG scanline")
    return {"sha256": sha256(path), "size": len(raw), "first_pixel": list(first[1:]),
            "width": width, "height": height, "validation": "all chunk CRCs, first decoded pixel, durable full-file digest"}


def source_ownership_case(library, resource, root, evidence):
    owned_resource = check_root(root / "owned Source resources")
    shutil.copytree(resource, owned_resource)
    source = check_root(owned_resource / "assets/examples/b2-owned.png")
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(tiny_png((12, 34, 56, 255)))
    original_hash = sha256(source)
    runtime = AsyncNative(library, owned_resource, root / "owned Source data", evidence)
    pumping = None
    try:
        runtime.submit_edit("editor.image.open", "pack://assets/examples/b2-owned.png")
        current = runtime.snapshot()[1].decode("utf-8")
        output_id = re.search(r"(?m)^output=(c\d+)$", current)
        require(output_id is not None, "image fixture snapshot omitted output identity")
        runtime.submit_edit("editor.resize.add", f"{output_id.group(1)} 4096 4096")
        # Actual useful pixel transforms make the capture/compute window observable.
        runtime.submit_edit("editor.invert.add")
        runtime.submit_edit("editor.invert.add")
        identity = runtime.submit_edit("editor.export.png", "session://exports/owned.png", ACCEPTED).task_id
        pumping = Pump(runtime)
        pumping.start()
        running = pumping.observe_running(identity)
        mutation = {"worker_alive_before": pumping.thread.is_alive()}
        if running is not None:
            source.write_bytes(tiny_png((200, 40, 80, 255)))
            mutation["worker_alive_after"] = pumping.thread.is_alive()
            require(sha256(source) != original_hash, "Source mutation fixture did not change its content")
        else:
            mutation["worker_alive_after"] = False
        pumping.finish()
        row = job(runtime, identity)
        output = png_first_pixel(runtime.data / "exports/owned.png", 4096, 4096)
        require(row["state"] == row["phase"] == "succeeded" and output["first_pixel"] == [12, 34, 56, 255]
                and digest_text(row["output_sha256"]) == output["sha256"] and row["output_size"] == output["size"],
                "captured Source worker used later live bytes or lost its successful output receipt")
        require(original_hash in record(runtime, identity)["job"]["document"], "job lost original Source declaration")
        if running is not None and mutation["worker_alive_before"] and mutation["worker_alive_after"]:
            evidence["checks"].append("real_Source_capture_is_owned_while_original_file_changes_during_resize_compute")
        else:
            evidence["inconclusive"].append("Source worker mutation missed the real capture-to-completion window")
        evidence["source_ownership"] = {"running": running, "mutation": mutation, "accepted_source_sha256": original_hash,
            "current_source_sha256": sha256(source), "job": row, "output": output}
    finally:
        if pumping is None or not pumping.thread.is_alive():
            runtime.close()


def pipe_jobs(wire, after=0):
    # Workspace.rpc has value=0; paged jobs use value=after in the wire header.
    connection = Pipe(wire.endpoint)
    header = struct.pack("<8sIIQII", b"CUTRSH2\0", JOBS_READ, 0, after, 0, 0)
    frame = {"kind": JOBS_READ, "request_header": header.hex(), "request_payload": ""}
    wire.frames.append(frame)
    try:
        connection.write(header)
        response = connection.read(32)
        frame["response_header"] = response.hex()
        magic, kind, status, value, length, reserved = struct.unpack("<8sIiQII", response)
        require(magic == b"CUTRSR2\0" and kind == JOBS_READ and status == OK and value == reserved == 0
                and 0 < length <= MAX_PAYLOAD, "invalid jobs RPC reply")
        payload = connection.read(length)
        frame["response_payload"] = payload.hex()
        return validate_page(json.loads(payload), after)
    finally:
        connection.close()


def wait_host_terminal(wire, identity):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        row = next(item for item in collect_pages(lambda after: pipe_jobs(wire, after)) if item["id"] == identity)
        if row["state"] in TERMINAL:
            return row
        threading.Event().wait(0.01)
    raise RuntimeError("autonomous Host did not reach a terminal outcome")


def host_retry_case(console, root, evidence):
    data = root / "async Host data"
    stopped = True
    try:
        _, before = invoke(console, "status", data, "portable")
        require(before["state"] == "unreachable", "claimed Host case already has a running instance")
        _, started = invoke(console, "start", data, "portable")
        stopped = False
        require(started["state"] == "running", "isolated async Host did not start")
        wire, client = Workspace(data, evidence), (0xB2A0, 0xB2A1)
        initial = wire.snapshot()
        fixture = check_root(data / "fixtures/tiny.cut")
        fixture.parent.mkdir(parents=True, exist_ok=True)
        fixture.write_text(TINY, encoding="utf-8")
        opened = wire.submit(wire.request(client, 1, initial["stamp"], "doc.open", "session://fixtures/tiny.cut"))
        require(opened["status"] == OK, "Host tiny document was rejected")
        blocked = check_root(data / "exports/blocked.png")
        blocked.mkdir(parents=True)
        sentinel = blocked / "sentinel.txt"
        sentinel.write_text("owned directory blocks atomic replacement", encoding="utf-8")
        accepted = wire.submit(wire.request(client, 2, opened["stamp"], "editor.export.png", "session://exports/blocked.png"))
        require(accepted["status"] == ACCEPTED and accepted["task_id"], "Host did not accept the failure fixture")
        parent = wait_host_terminal(wire, accepted["task_id"])
        require(parent["state"] == "failed" and sentinel.read_text(encoding="utf-8") == "owned directory blocks atomic replacement",
                "Host failure fixture did not preserve its original directory")
        edited = wire.submit(wire.request(client, 3, wire.snapshot()["stamp"], "editor.gain.set", "c1 0.8"))
        require(edited["status"] == OK, "Host current document edit was rejected")
        token = wire.request(client, 4, edited["stamp"], "task.retry", f"{parent['id']} session://exports/retry.png")
        child, replay = wire.submit(token), wire.submit(token)
        require(child["status"] == replay["status"] == ACCEPTED and child["task_id"] == replay["task_id"]
                and replay["disposition"] == 2, "Host exact retry token admitted duplicate work")
        target, frames_before = data / "exports/retry.png", len(wire.frames)
        deadline = time.monotonic() + 20
        while not target.is_file() and time.monotonic() < deadline:
            threading.Event().wait(0.01)
        require(target.is_file() and len(wire.frames) == frames_before, "Host retry required a Shell, pump or query")
        succeeded = wait_host_terminal(wire, child["task_id"])
        require(succeeded["retry_of"] == parent["id"] and succeeded["attempt"] == 2
                and succeeded["origin"] == parent["origin"] and succeeded["source_fingerprint"] == parent["source_fingerprint"],
                "Host retry lost its original version/lineage")
        output = assert_output(succeeded, target, (6, 19, 38, 255))
        rows = collect_pages(lambda after: pipe_jobs(wire, after))
        require(len(rows) == 2 and next(item for item in rows if item["id"] == parent["id"]) == parent,
                "Host retry rewrote its parent or duplicated attempts")
        text = run([str(console), "jobs", "--mode=portable", f"--data={data}"])
        cli = next((json.loads(line.split(" ", 1)[1]) for line in text.splitlines() if line.startswith("CUTRANS_VM_JOBS_JSON ")), None)
        require(cli is not None and any(item["id"] == succeeded["id"] and item["attempt"] == 2 for item in cli["items"]),
                "real CLI jobs omitted the retried attempt")
        _, final = invoke(console, "stop", data, "portable")
        require(final["state"] == "stopped", "async Host did not stop cleanly")
        stopped = True
        _, restarted = invoke(console, "start", data, "portable")
        stopped = False
        require(restarted["state"] == "running", "async Host did not restart")
        recovered = collect_pages(lambda after: pipe_jobs(wire, after))
        require(recovered == rows and sha256(target) == output["sha256"], "Host restart changed attempts or output")
        evidence["host_retry"] = {"parent": parent, "child": succeeded, "output": output, "restarted_jobs": recovered,
                                  "shell_attached": False, "rpc_frames_during_file_wait": 0}
        evidence["checks"].append("Shell_free_Host_exact_retry_runs_autonomously_and_survives_real_CLI_query_and_restart")
    finally:
        if not stopped:
            _, cleanup = invoke(console, "stop", data, "portable")
            require(cleanup["state"] == "stopped", "owned async Host cleanup failed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("jobs-async"))
    args = parser.parse_args()
    require(os.name == "nt", "real DLL/Host verification requires Windows")
    root = claim(args.root)
    portable = (OUTPUT / "portable").resolve()
    resource, before = portable / "runtime", hashes(portable)
    evidence = {"format": "cutrans-jobs-async-verification/1", "root": str(root), "artifact_hashes": before,
        "checks": [], "inconclusive": [], "passed": False,
        "limits": ["Real running windows are observed, not artificially delayed; missed windows are inconclusive",
                   "Deterministic owner-lock and Source barriers are separate source tests",
                   "Large Source PNG checks all chunk CRCs and first decoded pixel plus durable file digest, not every pixel",
                   "This does not verify GUI attachment, system registration/installation, or replace tools/verify_jobs.py B1 regression"]}
    try:
        library = ctypes.WinDLL(str(resource / "cutrans_vm_runtime.dll"))
        configure(library)
        require(library.cutrans_vm_abi_version() == identity()["host_api"], "Runtime ABI differs from product identity")
        queued_and_retry_case(library, resource, root, evidence)
        concurrent_cancel_case(library, resource, root, evidence)
        external_retry_case(library, resource, root, evidence)
        source_ownership_case(library, resource, root, evidence)
        host_retry_case(portable / "cutrans_vm.exe", root, evidence)
        require(hashes(portable) == before and not (portable / "data").exists(), "verification modified the tested artifact")
        evidence["passed"] = not evidence["inconclusive"]
        label = "OK" if evidence["passed"] else "INCONCLUSIVE"
        print(f"CUTRANS_JOBS_ASYNC_VERIFY_{label} checks={len(evidence['checks'])} inconclusive={len(evidence['inconclusive'])} evidence={root}")
        return 0 if evidence["passed"] else 2
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        evidence["artifact_hashes_after"] = hashes(portable)
        (root / "report.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)


if __name__ == "__main__":
    raise SystemExit(main())
