"""Verify Workspace API v1 over the distributed Host's real named pipe."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import struct
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from verification_context import canonical_path
from verification_paths import check_root, claim, default_root, retain
from verify_host import ABI_VERSION, hashes, invoke

MAX_PAYLOAD = 17 * 1024 * 1024
SNAPSHOT = 22
SUBMIT = 23


class Overlapped(ctypes.Structure):
    _fields_ = [("internal", ctypes.c_size_t), ("internal_high", ctypes.c_size_t),
                ("offset", ctypes.c_uint32), ("offset_high", ctypes.c_uint32),
                ("event", ctypes.c_void_p)]


class Pipe:
    """One RPC per connection, with bounded overlapped reads and writes."""

    def __init__(self, endpoint: str):
        self.win = ctypes.WinDLL("kernel32", use_last_error=True)
        declarations = {
            "CreateFileW": ([ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                             ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p], ctypes.c_void_p),
            "CreateEventW": ([ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_wchar_p], ctypes.c_void_p),
            "ReadFile": ([ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32,
                          ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(Overlapped)], ctypes.c_int),
            "WriteFile": ([ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32,
                           ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(Overlapped)], ctypes.c_int),
            "WaitForSingleObject": ([ctypes.c_void_p, ctypes.c_uint32], ctypes.c_uint32),
            "GetOverlappedResult": ([ctypes.c_void_p, ctypes.POINTER(Overlapped),
                                     ctypes.POINTER(ctypes.c_uint32), ctypes.c_int], ctypes.c_int),
            "CancelIoEx": ([ctypes.c_void_p, ctypes.POINTER(Overlapped)], ctypes.c_int),
            "CloseHandle": ([ctypes.c_void_p], ctypes.c_int),
        }
        for name, (arguments, result) in declarations.items():
            function = getattr(self.win, name)
            function.argtypes, function.restype = arguments, result
        deadline = time.monotonic() + 5
        while True:
            self.handle = self.win.CreateFileW(endpoint, 0xC0000000, 0, None, 3, 0x40000000, None)
            if self.handle not in (None, ctypes.c_void_p(-1).value):
                break
            error = ctypes.get_last_error()
            if time.monotonic() >= deadline:
                raise OSError(error, f"could not connect to isolated Host pipe: {endpoint}")
            time.sleep(0.02)

    def close(self) -> None:
        if self.handle is not None:
            self.win.CloseHandle(self.handle)
            self.handle = None

    def transfer(self, buffer: ctypes.Array, length: int, writing: bool) -> bytes:
        event = self.win.CreateEventW(None, 1, 0, None)
        if not event:
            raise ctypes.WinError(ctypes.get_last_error())
        operation = Overlapped(event=event)
        count = ctypes.c_uint32()
        try:
            function = self.win.WriteFile if writing else self.win.ReadFile
            if not function(self.handle, buffer, length, ctypes.byref(count), ctypes.byref(operation)):
                error = ctypes.get_last_error()
                if error != 997:  # ERROR_IO_PENDING
                    raise ctypes.WinError(error)
                if self.win.WaitForSingleObject(event, 5000) != 0:
                    self.win.CancelIoEx(self.handle, ctypes.byref(operation))
                    # Keep operation/buffer storage alive until cancellation completes.
                    self.win.GetOverlappedResult(self.handle, ctypes.byref(operation), ctypes.byref(count), 1)
                    raise TimeoutError("isolated Host pipe I/O exceeded five seconds")
                if not self.win.GetOverlappedResult(self.handle, ctypes.byref(operation), ctypes.byref(count), 0):
                    raise ctypes.WinError(ctypes.get_last_error())
            if count.value != length:
                raise RuntimeError(f"short Host pipe message: {count.value}, expected {length}")
            return buffer.raw[:count.value]
        finally:
            self.win.CloseHandle(event)

    def write(self, value: bytes) -> None:
        self.transfer(ctypes.create_string_buffer(value), len(value), True)

    def read(self, length: int) -> bytes:
        return self.transfer(ctypes.create_string_buffer(length), length, False)


class Workspace:
    def __init__(self, data: Path, evidence: dict):
        digest = hashlib.sha256(canonical_path(data).encode("utf-8")).hexdigest()
        self.endpoint = rf"\\.\pipe\cutrans-vm-{digest}"
        self.frames = evidence.setdefault("frames", [])

    def rpc(self, kind: int, payload: bytes, *, discard_outcome: bool = False) -> tuple[int, bytes]:
        header = struct.pack("<8sIIQII", b"CUTRSH2\0", kind, 0, 0, len(payload), 0)
        frame = {"kind": kind, "request_header": header.hex(), "request_payload": payload.hex()}
        self.frames.append(frame)
        connection = Pipe(self.endpoint)
        try:
            connection.write(header)
            if payload:
                connection.write(payload)
            response = connection.read(32)
            frame["response_header"] = response.hex()
            magic, actual_kind, status, value, length, reserved = struct.unpack("<8sIiQII", response)
            if magic != b"CUTRSR2\0" or actual_kind != kind or value != 0 or reserved != 0 or length > MAX_PAYLOAD:
                raise RuntimeError("invalid Workspace RPC response header")
            if discard_outcome:
                if status != 0 or length != 64:
                    raise RuntimeError("could not inject a lost Workspace Outcome")
                frame["response_payload_deliberately_discarded"] = True
                return status, b""
            result = connection.read(length) if length else b""
            frame["response_payload"] = result.hex()
            return status, result
        finally:
            connection.close()

    def snapshot(self, expected: tuple[int, int, int] | None = None, *, status: int = 0) -> dict | None:
        request = struct.pack("<IIQQQ", 1, int(expected is not None), *(expected or (0, 0, 0)))
        actual, payload = self.rpc(SNAPSHOT, request)
        if actual != status:
            raise RuntimeError(f"snapshot status {actual}, expected {status}")
        if actual != 0:
            if payload:
                raise RuntimeError("rejected snapshot returned document bytes")
            return None
        if len(payload) < 64:
            raise RuntimeError("missing snapshot metadata")
        version, flags, hi, lo, revision, fingerprint, high_water, length, reserved = struct.unpack("<II7Q", payload[:64])
        stamp = (hi, lo, revision)
        text = payload[64:]
        if (version != 1 or flags & ~3 or not (hi or lo) or not revision or reserved or
                length != len(text) or (expected is not None and expected != stamp)):
            raise RuntimeError("inconsistent Workspace snapshot")
        return {"stamp": stamp, "fingerprint": fingerprint, "high_water": high_water,
                "flags": flags, "text": text.decode("utf-8")}

    @staticmethod
    def request(client: tuple[int, int], sequence: int, expected: tuple[int, int, int],
                name: str, arg: str | None = None) -> bytes:
        name_bytes, arg_bytes = name.encode("utf-8"), (arg or "").encode("utf-8")
        return (struct.pack("<II6QII", 1, int(arg is not None), *client, sequence,
                            *expected, len(name_bytes), len(arg_bytes)) + name_bytes + arg_bytes)

    def submit(self, request: bytes) -> dict:
        status, payload = self.rpc(SUBMIT, request)
        if status != 0 or len(payload) != 64:
            raise RuntimeError(f"Workspace Outcome unknown: transport status={status}, length={len(payload)}")
        version, status, disposition, reserved, sequence, hi, lo, revision, created, task = struct.unpack("<IiII6Q", payload)
        if version != 1 or reserved or disposition not in (1, 2, 3):
            raise RuntimeError("invalid Workspace Outcome")
        if sequence != struct.unpack_from("<Q", request, 24)[0]:
            raise RuntimeError("Workspace Outcome sequence mismatch")
        return {"status": status, "disposition": disposition, "sequence": sequence,
                "stamp": (hi, lo, revision), "created_id": created, "task_id": task}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def verify(console: Path, host: Path, mode: str, root: Path) -> None:
    if os.name != "nt":
        raise RuntimeError("real named-pipe verification requires Windows")
    console, host = console.resolve(), host.resolve()
    require(console.is_file() and host.is_file(), "build the portable VM console and Host first")
    require(console.parent == host.parent, "console and Host must belong to the same artifact directory")
    root = check_root(root)
    claim(root)
    data = root / "workspace data"
    evidence = {"format": "cutrans-workspace-rpc-verification/1", "abi": ABI_VERSION,
                "mode": mode, "console": str(console), "host": str(host), "root": str(root),
                "artifact_hashes": hashes(console.parent), "passed": False}
    stopped = False
    try:
        _, current = invoke(console, "status", data, mode)
        require(current["state"] == "unreachable", "verification data unexpectedly has a live Host")
        _, started = invoke(console, "start", data, mode)
        require(started["state"] == "running" and started["abi"] == ABI_VERSION, "Host did not start with the declared ABI")
        wire = Workspace(data, evidence)
        initial = wire.snapshot()
        require(wire.snapshot(initial["stamp"]) == initial, "same stamp produced a different snapshot")
        (root / "snapshot-initial.txt").write_text(initial["text"], encoding="utf-8")

        client_a, client_b = (0xA201, 0xA202), (0xB201, 0xB202)
        edit = wire.request(client_a, 1, initial["stamp"], "editor.invert.add", "c1")
        first = wire.submit(edit)
        require(first["status"] == 0 and first["disposition"] == 1 and first["created_id"] > initial["high_water"], "created node identity was not returned")
        after_edit = wire.snapshot(first["stamp"])
        require(after_edit["stamp"][2] > initial["stamp"][2] and after_edit["high_water"] == first["created_id"], "edit did not publish one coherent new snapshot")
        replay = wire.submit(edit)
        require(replay == {**first, "disposition": 2} and wire.snapshot() == after_edit, "duplicate edit executed again or lost its created node receipt")
        conflict = wire.submit(wire.request(client_a, 1, initial["stamp"], "editor.invert.add", "c0"))
        require(conflict["status"] == 18 and conflict["disposition"] == 3 and wire.snapshot() == after_edit, "changed payload reused an edit token")

        other = wire.submit(wire.request(client_b, 1, after_edit["stamp"], "editor.gain.set", "c1 0.4"))
        require(other["status"] == 0 and other["disposition"] == 1, "second client did not mutate the shared document")
        after_other = wire.snapshot(other["stamp"])
        require(after_other["stamp"][2] > after_edit["stamp"][2] and after_other["fingerprint"] != after_edit["fingerprint"], "second client failed to publish a new version")
        stale = wire.submit(wire.request(client_a, 2, after_edit["stamp"], "history.undo"))
        require(stale["status"] == 16 and stale["disposition"] == 3 and stale["stamp"] == after_other["stamp"], "stale edit was not explicitly rejected")
        require(wire.snapshot() == after_other, "stale edit changed the document")
        wire.snapshot(after_edit["stamp"], status=16)
        wrong_epoch = (after_other["stamp"][0] ^ 1, *after_other["stamp"][1:])
        wire.snapshot(wrong_epoch, status=17)

        export = wire.request(client_a, 3, after_other["stamp"], "editor.export.png", "session://exports/workspace-rpc.png")
        wire.rpc(SUBMIT, export, discard_outcome=True)
        admitted, admitted_again = wire.submit(export), wire.submit(export)
        require(admitted["status"] == 1 and admitted["disposition"] == 2 and admitted["task_id"] != 0 and admitted_again == admitted, "lost export Outcome did not replay the same task admission")
        journal = (data / "tasks/journal.txt").read_text(encoding="utf-8")
        tasks = [line for line in journal.splitlines() if line.startswith("task=")]
        require(len(tasks) == 1 and tasks[0].startswith(f'task={admitted["task_id"]},'), "replayed export admission allocated more than one task")
        require(wire.snapshot() == after_other, "export admission changed the document snapshot")
        (root / "tasks-after-replay.txt").write_text(journal, encoding="utf-8")
        (root / "snapshot-after-edits.txt").write_text(after_other["text"], encoding="utf-8")
        evidence.update(initial=initial, created=first, replay=replay, token_conflict=conflict,
                        other_client=other, stale=stale, export_receipt=admitted, task_count=len(tasks))

        _, final = invoke(console, "stop", data, mode)
        require(final["state"] == "stopped", "Host did not stop after the RPC verification")
        stopped = True
        _, restarted = invoke(console, "start", data, mode)
        stopped = False
        require(restarted["state"] == "running", "Host did not restart")
        fresh = wire.snapshot()
        require(fresh["stamp"][:2] != after_other["stamp"][:2], "restarted Runtime reused the old incarnation")
        expired = wire.submit(export)
        require(expired["status"] == 17 and expired["disposition"] == 3 and expired["task_id"] == 0, "old-incarnation request was executed after restart")
        require(fresh["fingerprint"] == after_other["fingerprint"] and fresh["text"] == after_other["text"], "Host restart lost the accepted document")
        evidence.update(restarted_snapshot=fresh, old_incarnation=expired)
        _, final = invoke(console, "stop", data, mode)
        require(final["state"] == "stopped", "restarted Host did not stop")
        stopped = True
        require(hashes(console.parent) == evidence["artifact_hashes"], "RPC verification modified the tested artifact")
        evidence["passed"] = True
        print("CUTRANS_WORKSPACE_RPC_VERIFY_OK coherent_snapshot=1 edit_replay=1 created_id=1 stale=1 token_conflict=1 lost_outcome=1 export_task_replay=1 task_count=1 restart_epoch=1")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        if not stopped:
            try:
                _, cleanup = invoke(console, "stop", data, mode)
                evidence["cleanup_state"] = cleanup
            except Exception as error:
                evidence["cleanup_error"] = repr(error)
                print(f"Host cleanup stop: {error}")
        (root / "workspace-rpc.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)
        print(f"Workspace RPC evidence retained: {root}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--console", type=Path, default=OUTPUT / "portable/cutrans_vm.exe")
    parser.add_argument("--host", type=Path, default=OUTPUT / "portable/cutrans_vm_host.exe")
    parser.add_argument("--mode", choices=("portable", "installed"), default="portable")
    parser.add_argument("--root", type=Path, default=default_root("workspace-rpc"))
    args = parser.parse_args()
    verify(args.console, args.host, args.mode, args.root)


if __name__ == "__main__":
    main()
