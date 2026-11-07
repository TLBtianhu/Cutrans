"""Probe edit failures against the distributed Runtime in owned verification cases."""
from __future__ import annotations

import ctypes
import json
from pathlib import Path

from build_paths import OUTPUT
from verification_paths import claim, default_root, retain, check_root
from verification_context import mark_data
from verify_input import ABI_VERSION, Config, ByteSlice, string_slice, hashes


def configure(library):
    library.cutrans_vm_create.argtypes = [ctypes.POINTER(Config), ctypes.POINTER(ctypes.c_void_p)]
    library.cutrans_vm_create.restype = ctypes.c_int32
    library.cutrans_vm_destroy.argtypes = [ctypes.c_void_p]
    library.cutrans_vm_command.argtypes = [ctypes.c_void_p, ByteSlice, ByteSlice]
    library.cutrans_vm_command.restype = ctypes.c_int32
    library.cutrans_vm_command_result.argtypes = [ctypes.c_void_p, ByteSlice, ByteSlice, ctypes.POINTER(ctypes.c_uint64)]
    library.cutrans_vm_command_result.restype = ctypes.c_int32
    library.cutrans_vm_document_read.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    library.cutrans_vm_document_read.restype = ctypes.c_int32
    library.cutrans_vm_document_fingerprint.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint64)]
    library.cutrans_vm_document_flags.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]


def command(library, handle, name, arg=None, expected=0):
    name_value, name_storage = string_slice(name)
    arg_value, arg_storage = string_slice(arg) if arg is not None else (ByteSlice(), None)
    task_id = ctypes.c_uint64(999)
    status = library.cutrans_vm_command_result(handle, name_value, arg_value, ctypes.byref(task_id))
    if status != 1 and task_id.value != 0:
        raise RuntimeError("synchronous or failed command leaked an old task ID")
    if status != expected:
        raise RuntimeError(f"{name} {arg}: status={status}, expected={expected}")


def state(library, handle):
    required = ctypes.c_size_t()
    if library.cutrans_vm_document_read(handle, None, 0, ctypes.byref(required)) != 15:
        raise RuntimeError("document size query failed")
    buffer = ctypes.create_string_buffer(required.value)
    if library.cutrans_vm_document_read(handle, buffer, len(buffer), ctypes.byref(required)):
        raise RuntimeError("document read failed")
    fingerprint, flags = ctypes.c_uint64(), ctypes.c_uint32()
    if library.cutrans_vm_document_fingerprint(handle, ctypes.byref(fingerprint)) or library.cutrans_vm_document_flags(handle, ctypes.byref(flags)):
        raise RuntimeError("document metadata read failed")
    return buffer.raw[:required.value], fingerprint.value, flags.value


def exclusive_file(path):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                                   ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.CreateFileW(str(check_root(path)), 0x80000000, 0, None, 3, 0x80, None)
    if handle in (None, ctypes.c_void_p(-1).value):
        raise ctypes.WinError(ctypes.get_last_error())
    return kernel, handle


def main():
    root = claim(default_root("edit-commit"))
    resource = (OUTPUT / "portable/runtime").resolve()
    before_pack = hashes(resource)
    library = ctypes.WinDLL(str(resource / "cutrans_vm_runtime.dll"))
    configure(library)
    checks = []

    def create(name):
        data = mark_data(root / name, "portable", resource)
        resource_value, resource_storage = string_slice(str(resource))
        data_value, data_storage = string_slice(str(data))
        config = Config(ctypes.sizeof(Config), ABI_VERSION, 1, 0, resource_value, data_value)
        handle = ctypes.c_void_p()
        if library.cutrans_vm_create(ctypes.byref(config), ctypes.byref(handle)) or not handle.value:
            raise RuntimeError("could not create isolated distributed Runtime")
        return handle, data

    handle, data = create("persistence data")
    try:
        command(library, handle, "editor.gain.set", "c1 0.25")
        command(library, handle, "doc.save")
        journal = data / "documents/history.txt"
        old_journal = journal.read_bytes()
        old_state = state(library, handle)
        kernel, lock = exclusive_file(journal)
        try:
            for name, arg in (("editor.gain.set", "c1 0.5"), ("editor.invert.add", "c1"), ("history.undo", None)):
                command(library, handle, name, arg, expected=8)
                if state(library, handle) != old_state:
                    raise RuntimeError(f"{name}: persistence failure changed the published document")
        finally:
            kernel.CloseHandle(lock)
        if journal.read_bytes() != old_journal:
            raise RuntimeError("failed edits changed the committed History")
        command(library, handle, "history.undo")
        undone = state(library, handle)
        undone_journal = journal.read_bytes()
        kernel, lock = exclusive_file(journal)
        try:
            command(library, handle, "history.redo", expected=8)
            if state(library, handle) != undone:
                raise RuntimeError("failed redo changed document or dirty flags")
        finally:
            kernel.CloseHandle(lock)
        if journal.read_bytes() != undone_journal:
            raise RuntimeError("failed redo changed History cursor on disk")
        command(library, handle, "history.redo")
        checks.append("exclusive_journal_lock_edit_undo_redo_unchanged_retry_ok")
        baseline = state(library, handle)
        for value in ("nan", "inf", "-inf"):
            command(library, handle, "editor.gain.set", "c1 " + value, expected=3)
            if state(library, handle) != baseline:
                raise RuntimeError("invalid floating input changed document")
        checks.append("nonfinite_parameters_rejected")
        command(library, handle, "editor.invert.add", "c1")
        first_ids = node_ids(state(library, handle)[0])
        command(library, handle, "history.undo")
    finally:
        library.cutrans_vm_destroy(handle)
    handle, _ = create("persistence data")
    try:
        command(library, handle, "editor.invert.add", "c1")
        if max(node_ids(state(library, handle)[0])) <= max(first_ids):
            raise RuntimeError("History restore and new branch reused a committed node ID")
        checks.append("node_identity_survives_undo_restore_new_branch")
    finally:
        library.cutrans_vm_destroy(handle)

    handle, full_data = create("full history data")
    try:
        for index in range(256):
            command(library, handle, "editor.gain.set", "c1 " + ("0.25" if index % 2 else "0.5"))
        baseline = state(library, handle)
        journal = full_data / "documents/history.txt"
        committed = journal.read_bytes()
        for name, arg in (("editor.gain.set", "c1 0.75"), ("editor.invert.add", "c1")):
            command(library, handle, name, arg, expected=8)
            if state(library, handle) != baseline or journal.read_bytes() != committed:
                raise RuntimeError("HistoryFull changed live state or durable journal")
        command(library, handle, "history.undo")
        command(library, handle, "editor.gain.set", "c1 0.75")
        command(library, handle, "history.redo", expected=5)
        checks.append("history_full_unchanged_undo_branch_retry_ok")
    finally:
        library.cutrans_vm_destroy(handle)
    if hashes(resource) != before_pack:
        raise RuntimeError("edit verification modified the distributed Runtime Pack")
    report = {"format": "cutrans-edit-commit-evidence/1", "checks": checks, "runtime_files": before_pack,
              "system_registration": "not performed", "real_user_data": "untouched"}
    (root / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    retain(root)
    print(f"CUTRANS_EDIT_COMMIT_OK checks={len(checks)} journal_failure=unchanged identity=stable pack_unchanged=1 evidence={root}")


def node_ids(text):
    return [int(line.split(b"=", 1)[0][1:]) for line in text.splitlines() if line.startswith(b"c") and b"=" in line]


if __name__ == "__main__":
    main()
