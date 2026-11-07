"""Probe bounded Host pipe failure handling against an unchanged real portable artifact."""

from __future__ import annotations

import argparse
import binascii
import ctypes
import hashlib
import json
import os
import struct
import sys
import time
import zlib
from pathlib import Path

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from verification_paths import check_root, claim, default_root, retain
from verify_host import ABI_VERSION, hashes, host_pid, invoke
from verify_workspace_rpc import MAX_PAYLOAD, Pipe, Workspace


class MessagePipe(Pipe):
    def __init__(self, endpoint):
        super().__init__(endpoint)
        setter = self.win.SetNamedPipeHandleState
        setter.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p, ctypes.c_void_p]
        setter.restype = ctypes.c_int
        mode = ctypes.c_uint32(2)  # Match the production client's message-read mode.
        if not setter(self.handle, ctypes.byref(mode), None, None):
            error = ctypes.get_last_error()
            self.close()
            raise ctypes.WinError(error)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def header(kind, length=0, identifier=0):
    return struct.pack("<8sIIQII", b"CUTRSH2\0", kind, 0, identifier, length, 0)


def response(connection, kind):
    encoded = connection.read(32)
    magic, returned_kind, status, value, length, reserved = struct.unpack("<8sIiQII", encoded)
    require(magic == b"CUTRSR2\0" and returned_kind == kind and reserved == 0 and length <= MAX_PAYLOAD,
            "invalid real Host response frame")
    return encoded, status, value, length


def rpc(endpoint, evidence, kind, payload=b"", identifier=0, delay=0):
    connection = MessagePipe(endpoint)
    frame = {"kind": kind, "request_header": header(kind, len(payload), identifier).hex(),
             "request_payload": payload.hex(), "delay_before_each_read": delay}
    evidence["frames"].append(frame)
    try:
        connection.write(bytes.fromhex(frame["request_header"]))
        if payload:
            connection.write(payload)
        if delay:
            time.sleep(delay)
        encoded, status, value, length = response(connection, kind)
        frame["response_header"] = encoded.hex()
        if delay:
            time.sleep(delay)
        body = connection.read(length) if length else b""
        frame["response_payload_size"] = len(body)
        frame["response_payload_sha256"] = hashlib.sha256(body).hexdigest()
        if len(body) <= 2048:
            frame["response_payload"] = body.hex()
        return status, value, body
    finally:
        connection.close()


def await_ready(console, data, evidence, case, deadline_seconds=9):
    start = time.monotonic()
    states = []
    deadline = start + deadline_seconds
    while time.monotonic() < deadline:
        _, current = invoke(console, "status", data, "portable")
        states.append(current)
        if current["state"] == "running":
            elapsed = time.monotonic() - start
            require(current["abi"] == ABI_VERSION, "Host identity changed during a malformed connection")
            evidence["checks"].append({"case": case, "recovery_seconds": elapsed, "states": states})
            return
        time.sleep(0.02)
    raise RuntimeError(f"Host did not recover from {case} while the offending client handle stayed open: {states}")


def synthetic_png(path):
    width, height = 256, 256
    pixels = hashlib.shake_256(b"Cutrans owned transport fixture, no user media").digest(width * height * 4)
    rows = b"".join(b"\0" + pixels[y * width * 4:(y + 1) * width * 4] for y in range(height))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", binascii.crc32(kind + body) & 0xffffffff)

    encoded = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(encoded)
    return encoded


def verify(root):
    require(os.name == "nt", "real Windows named-pipe verification requires Windows")
    root = claim(root)
    portable = OUTPUT / "portable"
    console, host = portable / "cutrans_vm.exe", portable / "cutrans_vm_host.exe"
    require(console.is_file() and host.is_file(), "build the portable console and Host before this probe")
    data = root / "transport data"
    evidence = {"format": "cutrans-host-transport-verification/1", "root": str(root),
                "artifact_hashes": hashes(portable), "checks": [], "frames": [], "passed": False,
                "limits": ["One connection can occupy the serial Host for its bounded I/O timeout",
                           "Cancellation completion relies on Windows NPFS honoring targeted cancellation",
                           "No installer, GUI, or system registration is exercised"]}
    stopped = False
    try:
        _, initial = invoke(console, "status", data, "portable")
        require(initial["state"] == "unreachable", "claimed verification case unexpectedly owns a live Host")
        _, started = invoke(console, "start", data, "portable")
        require(started["state"] == "running" and started["abi"] == ABI_VERSION, "isolated Host did not start")
        wire = Workspace(data, evidence)
        baseline = wire.snapshot()
        snapshot_request = struct.pack("<IIQQQ", 1, 0, 0, 0, 0)
        status, value, slow = rpc(wire.endpoint, evidence, 22, snapshot_request, delay=0.15)
        require(status == value == 0 and slow[64:].decode("utf-8") == baseline["text"], "slow reader lost a buffered snapshot reply")
        evidence["checks"].append({"case": "delayed_header_and_body_read_preserves_snapshot"})

        fixture = check_root(data / "fixtures/large.png")
        fixture_bytes = synthetic_png(fixture)
        status, asset_id, body = rpc(wire.endpoint, evidence, 16, str(fixture).encode("utf-8"))
        require(status == 1 and asset_id != 0 and not body, "could not open the synthetic PNG in the isolated Runtime")
        status, value, body = rpc(wire.endpoint, evidence, 15, identifier=asset_id, delay=0.1)
        require(status == value == 0 and body == fixture_bytes and len(body) > 128 * 1024, "large slow-read reply was truncated or corrupted")
        evidence["checks"].append({"case": "large_slow_read_preserves_all_message_bytes", "bytes": len(body),
                                   "sha256": hashlib.sha256(body).hexdigest()})

        for case in ("silent_client_read_timeout", "unread_small_reply", "unread_large_body_write_timeout"):
            peer = MessagePipe(wire.endpoint)
            try:
                if case == "unread_small_reply":
                    peer.write(header(22, len(snapshot_request)))
                    peer.write(snapshot_request)
                elif case == "unread_large_body_write_timeout":
                    peer.write(header(15, identifier=asset_id))
                    encoded, status, value, length = response(peer, 15)
                    require(status == value == 0 and length == len(fixture_bytes), "large-body negative case did not reach its write")
                    evidence["frames"].append({"kind": 15, "request_header": header(15, identifier=asset_id).hex(),
                                               "response_header": encoded.hex(), "payload_deliberately_unread": True})
                # Keep the misbehaving handle open until a different real client succeeds.
                await_ready(console, data, evidence, case)
            finally:
                peer.close()
            require(wire.snapshot() == baseline, f"{case} damaged the Runtime document")

        peer = MessagePipe(wire.endpoint)
        try:
            peer.write(header(22, len(snapshot_request)))
            peer.write(snapshot_request[:16])
            await_ready(console, data, evidence, "truncated_rpc_payload_rejected")
        finally:
            peer.close()

        for _ in range(16):
            peer = MessagePipe(wire.endpoint)
            try:
                peer.write(header(22, len(snapshot_request)))
                peer.write(snapshot_request)
                # Discard the response by closing at the transport boundary.
            finally:
                peer.close()
        await_ready(console, data, evidence, "repeated_disconnect_during_reply")
        for _ in range(32):
            require(wire.snapshot() == baseline, "reply loss or timeout left stale overlapped I/O in a later request")
        evidence["checks"].append({"case": "thirty_two_fresh_requests_after_cancellation_and_disconnect", "count": 32})
        _, final = invoke(console, "stop", data, "portable")
        require(final["state"] == "stopped", "Host did not stop after transport failures")
        stopped = True
        require(host_pid(host, data, "portable") is None, "owned transport Host survived its successful stop")
        require(hashes(portable) == evidence["artifact_hashes"], "transport verification modified the tested artifact")
        evidence["passed"] = True
        print(f"CUTRANS_HOST_TRANSPORT_VERIFY_OK checks={len(evidence['checks'])} delayed_read=1 bounded_unread_peer=1 canceled_read=1 canceled_write=1 truncated=1 disconnect_recovery=1 evidence={root}")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        if not stopped:
            try:
                _, cleanup = invoke(console, "stop", data, "portable")
                evidence["cleanup_state"] = cleanup
            except Exception as error:
                evidence["cleanup_error"] = repr(error)
        evidence["artifact_hashes_after"] = hashes(portable)
        (root / "report.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("host-transport"))
    args = parser.parse_args()
    verify(args.root)


if __name__ == "__main__":
    main()
