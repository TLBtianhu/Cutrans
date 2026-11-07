"""C2a real DLL/Host checks for corrected Win32 identity and safe legacy grants.

This verifies identity repair, not the future resource CAS/relink/adopt features.
All files are synthetic and beneath one claimed verification root. No GUI or
system registration is used; child processes use verify_host's quiet wrapper.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import struct
import sys
from pathlib import Path

sys.dont_write_bytecode = True

from build_paths import OUTPUT
from product import identity
from verification_paths import check_root, claim, default_root, retain
from verify_assets import asset_projection
from verify_edit_commit import exclusive_file
from verify_host import invoke
from verify_input import hashes
from verify_jobs import ACCEPTED, FAILED, OK, require, sha256, tiny_png
from verify_jobs_async import AsyncNative, wait_host_terminal
from verify_resource_versions import (assert_output, configure, document_state,
    export as export_version, history_bytes, host_legacy, host_listing, host_rpc,
    host_source_read, import_source, listing, pin_path, preview, source_read,
    wait_host_file)
from verify_workspace_rpc import Workspace

INVALID_ARGUMENTS, INVALID_STATE, LEGACY_UNVERIFIED = 3, 5, 16
VERIFIED, LEGACY = "win32-file-id/1", "legacy-cutrans-layout/1"
COLOR = (12, 34, 56, 255)


class FileTime(ctypes.Structure):
    _fields_ = [("low", ctypes.c_uint32), ("high", ctypes.c_uint32)]


class ByHandleFileInformation(ctypes.Structure):
    # Exact Win32 BY_HANDLE_FILE_INFORMATION layout, independent of Zig's Port.
    _fields_ = [("attributes", ctypes.c_uint32), ("creation", FileTime),
                ("access", FileTime), ("write", FileTime),
                ("volume_serial", ctypes.c_uint32), ("size_high", ctypes.c_uint32),
                ("size_low", ctypes.c_uint32), ("links", ctypes.c_uint32),
                ("index_high", ctypes.c_uint32), ("index_low", ctypes.c_uint32)]


def win_identity(path):
    path = check_root(path)
    require(path.is_file(), "identity cross-check only accepts an owned synthetic file")
    require(ctypes.sizeof(ByHandleFileInformation) == 52
            and ByHandleFileInformation.volume_serial.offset == 28
            and ByHandleFileInformation.index_high.offset == 44
            and ByHandleFileInformation.index_low.offset == 48,
            "Python Win32 identity layout is wrong")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                                  ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.GetFileInformationByHandle.argtypes = [ctypes.c_void_p, ctypes.POINTER(ByHandleFileInformation)]
    kernel.GetFileInformationByHandle.restype = ctypes.c_int
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel.CloseHandle.restype = ctypes.c_int
    handle = kernel.CreateFileW(str(path), 0x80000000, 7, None, 3, 0x80, None)
    if handle in (None, ctypes.c_void_p(-1).value):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        information = ByHandleFileInformation()
        if not kernel.GetFileInformationByHandle(handle, ctypes.byref(information)):
            raise ctypes.WinError(ctypes.get_last_error())
        raw = bytes(information)
        return {"volume_serial": information.volume_serial,
                "file_index": (information.index_high << 32) | information.index_low,
                "legacy_layout_volume_serial": struct.unpack_from("<I", raw, 24)[0],
                "legacy_layout_file_index": (struct.unpack_from("<I", raw, 40)[0] << 32)
                                            | struct.unpack_from("<I", raw, 44)[0]}
    finally:
        kernel.CloseHandle(handle)


def auth_path(data):
    return check_root(data / "session/external-sources.json")


def auth(data):
    return json.loads(auth_path(data).read_text(encoding="utf-8"))


def entry_for(data, grant):
    return next(entry for entry in auth(data)["sources"] if entry["id"] == grant)


def library_bytes(data):
    path = data / "library/catalog.json"
    return path.read_bytes() if path.is_file() else None


def unchanged_state(runtime):
    return {"document": document_state(runtime), "history": history_bytes(runtime.data),
            "library": library_bytes(runtime.data), "authorizations": auth_path(runtime.data).read_bytes()}


def assert_real_entry(entry, observed):
    require(entry["identity_scheme"] == VERIFIED
            and entry["volume_serial"] == observed["volume_serial"]
            and entry["file_index"] == observed["file_index"],
            "serialized grant identity differs from independent GetFileInformationByHandle")


def confirmation(grant, digest, path):
    # The path is an absolute remainder, not a shell command or quoted parser token.
    return f"{grant} {digest} {path}"


def legacy_fixture(data, observed, evidence_path):
    current = auth(data)
    entries = []
    for entry in current["sources"]:
        entry = dict(entry)
        entry.pop("identity_scheme", None)
        actual = observed[entry["id"]]
        entry["volume_serial"] = actual["legacy_layout_volume_serial"]
        entry["file_index"] = actual["legacy_layout_file_index"]
        require((entry["volume_serial"], entry["file_index"]) != (actual["volume_serial"], actual["file_index"]),
                "legacy fixture unexpectedly contains the corrected physical identity")
        entries.append(entry)
    value = {"format": "cutrans-external-sources/1", "sources": entries}
    raw = (json.dumps(value, indent=2) + "\n").encode("utf-8")
    auth_path(data).write_bytes(raw)
    check_root(evidence_path).write_bytes(raw)
    return raw, value


def real_identity_cases(library, resource, root, evidence):
    data = root / "correct physical identities data"
    a, b = check_root(root / "same bytes A.png"), check_root(root / "same bytes B.png")
    content = tiny_png(COLOR)
    a.write_bytes(content)
    b.write_bytes(content)
    ia, ib = win_identity(a), win_identity(b)
    require((ia["volume_serial"], ia["file_index"]) != (ib["volume_serial"], ib["file_index"]),
            "two synthetic files did not have distinct real identities")
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        handle_a, handle_b = import_source(runtime, a), import_source(runtime, b)
        require(auth(data)["format"] == "cutrans-external-sources/2", "new imports did not use identity-aware schema v2")
        assert_real_entry(entry_for(data, 1), ia)
        assert_real_entry(entry_for(data, 2), ib)
        before_auth, before_library = auth_path(data).read_bytes(), library_bytes(data)
        reused = import_source(runtime, a)
        require(reused == handle_a and len(auth(data)["sources"]) == 2 and auth_path(data).read_bytes() == before_auth
                and library_bytes(data) == before_library, "same physical path/bytes allocated another persistent identity")
        runtime.legacy("asset.release", str(reused))
        evidence["physical_identity"] = {"A": ia, "B": ib, "entries": auth(data)["sources"]}
        evidence["checks"].append("new_v2_grants_match_independent_Win32_identity_and_same_path_import_reuses_identity")

        # Raw temporary external Sources test file identity, not the already
        # distinct library IDs which could hide a broken file-identity Port.
        grant_a, grant_b = runtime.grant(a, False), runtime.grant(b, False)
        before = listing(runtime)
        runtime.legacy("asset.open", f"external://{grant_a}", ACCEPTED)
        after_a = listing(runtime)
        raw_a = next(iter(set(after_a) - set(before)))
        runtime.legacy("asset.open", f"external://{grant_b}", ACCEPTED)
        after_b = listing(runtime)
        require(len(after_b) == len(after_a) + 1, "same-hash different physical Sources collapsed to one Station handle")
        raw_b = next(iter(set(after_b) - set(after_a)))
        require(raw_a != raw_b and raw_a not in (handle_a, handle_b) and raw_b not in (handle_a, handle_b),
                "raw Source fixture did not isolate file identity from library identity")
        for handle, grant in ((raw_a, grant_a), (raw_b, grant_b)):
            info, actual, uri = asset_projection(library, runtime.handle, handle)
            require(actual == content and uri == f"external://{grant}", "raw Station Source has the other file's URI or bytes")
        evidence["raw_physical_sources"] = {"temporary_grants": [grant_a, grant_b], "Station_handles": [raw_a, raw_b]}
        evidence["checks"].append("same_hash_different_real_files_do_not_merge_as_raw_external_Station_sources")
    finally:
        runtime.close()


def atomic_replacement_case(library, resource, root, evidence):
    data = root / "verified replacement data"
    source, replacement = check_root(root / "verified original.png"), check_root(root / "verified replacement.png")
    content = tiny_png(COLOR)
    source.write_bytes(content)
    replacement.write_bytes(content)
    original, candidate = win_identity(source), win_identity(replacement)
    require(original["file_index"] != candidate["file_index"], "replacement fixture did not allocate a new file")
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        handle = import_source(runtime, source)
        runtime.submit_edit("editor.asset.insert", str(handle))
        before = unchanged_state(runtime)
        os.replace(replacement, source)  # Two exact owned files; no recursive or link-following operation.
        actual = win_identity(source)
        require(actual["file_index"] == candidate["file_index"] and sha256(source) == hashlib.sha256(content).hexdigest(),
                "same-content atomic replacement fixture is invalid")
        source_read(runtime, "external://1", expected=FAILED)
        runtime.legacy("asset.open", "library://1", FAILED)
        runtime.legacy("source.reauthorize", confirmation(1, sha256(source), source), INVALID_STATE)
        require(unchanged_state(runtime) == before, "atomic replacement silently reassigned an already verified grant")
        preview(runtime)
        output = export_version(runtime, "retained-after-replacement.png", COLOR)
        parked = check_root(root / "preserved replaced physical file.png")
        require(not parked.exists(), "directory replacement fixture would overwrite an existing file")
        source.rename(parked)  # Preserve this exact owned file; do not delete it.
        source.mkdir()
        digest = hashlib.sha256(content).hexdigest()
        manifest = {"format": "cutrans-content-snapshot/1", "snapshot_id": digest,
            "content": {"path": "content.bin", "byteLength": len(content), "sha256": digest},
            "provenance": {"source_kind": "external", "source": "external://1"}}
        (source / "content.bin").write_bytes(content)
        (source / "snapshot.json").write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        before_directory_read = unchanged_state(runtime)
        source_read(runtime, "external://1", expected=FAILED)
        runtime.legacy("asset.open", "external://1", FAILED)
        runtime.legacy("asset.open", "library://1", FAILED)
        require(unchanged_state(runtime) == before_directory_read,
                "a known persistent file grant was reinterpreted as a directory Content Snapshot")
        require((source / "content.bin").read_bytes() == content and sha256(parked) == digest,
                "directory rejection modified the synthetic snapshot or preserved file")
        evidence["atomic_replacement"] = {"before": original, "after": actual, "retained_export": output,
            "directory_snapshot_at_old_file_path": str(source), "preserved_replaced_file": str(parked),
            "directory_manifest": manifest}
        evidence["checks"].append("same_hash_file_or_snapshot_directory_replacement_cannot_reuse_verified_file_authority_but_retained_work_renders")
    finally:
        runtime.close()


def legacy_migration_cases(library, resource, root, evidence):
    data = root / "legacy identity migration data"
    source, other = check_root(root / "legacy selected source.png"), check_root(root / "legacy other source.png")
    content = tiny_png(COLOR)
    source.write_bytes(content)
    other.write_bytes(content)
    digest = hashlib.sha256(content).hexdigest()
    observed = {1: win_identity(source), 2: win_identity(other)}
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        selected = import_source(runtime, source)
        import_source(runtime, other)
        runtime.submit_edit("editor.asset.insert", str(selected))
        runtime.legacy("doc.save", "session://legacy-work.cut")
        retained = pin_path(data, digest)
        require(retained.read_bytes() == content, "legacy migration fixture did not retain its adopted Source")
    finally:
        runtime.close()
    raw, legacy = legacy_fixture(data, observed, root / "legacy-raw-input.json")
    runtime = AsyncNative(library, resource, data, evidence)
    try:
        require(auth_path(data).read_bytes() == raw, "read-only v1 restoration overwrote the original identity evidence")
        require(not listing(runtime), "legacy restoration revived live Station state")
        before = unchanged_state(runtime)
        source_read(runtime, "external://1", expected=LEGACY_UNVERIFIED)
        runtime.legacy("asset.open", "library://1", INVALID_STATE)
        require(unchanged_state(runtime) == before, "denying legacy authority rewrote a record or changed the current work")
        require(source_read(runtime, "library://1", digest) == content, "legacy authority blocked its already retained library Source")
        preview(runtime)
        output = export_version(runtime, "legacy-retained-cold.png", COLOR)
        require(auth_path(data).read_bytes() == raw, "retained render/export silently confirmed an old physical identity")
        evidence["legacy_denied_retained_allowed"] = {"raw_identity": legacy, "retained_export": output}
        evidence["checks"].append("legacy_v1_stays_raw_and_unverified_while_retained_adopted_work_exports_after_cold_restart")

        before = unchanged_state(runtime)
        runtime.legacy("source.reauthorize", confirmation(1, "f" * 64, source), INVALID_STATE)
        runtime.legacy("source.reauthorize", confirmation(1, digest, other), INVALID_ARGUMENTS)
        runtime.legacy("source.reauthorize", f"1 not-a-hash {source}", INVALID_ARGUMENTS)
        require(unchanged_state(runtime) == before, "wrong confirmation hash/path/syntax changed document, history or catalogs")
        kernel, lock = exclusive_file(auth_path(data))
        try:
            runtime.legacy("source.reauthorize", confirmation(1, digest, source), FAILED)
        finally:
            kernel.CloseHandle(lock)
        require(unchanged_state(runtime) == before, "failed authorization save published a partial identity confirmation")
        evidence["checks"].append("wrong_hash_path_syntax_and_locked_authorization_file_preserve_document_history_and_both_catalogs")

        runtime.legacy("source.reauthorize", confirmation(1, digest, source))
        confirmed = auth(data)
        require(confirmed["format"] == "cutrans-external-sources/2", "explicit confirmation did not save v2")
        assert_real_entry(entry_for(data, 1), observed[1])
        unconfirmed = entry_for(data, 2)
        require(unconfirmed["identity_scheme"] == LEGACY
                and unconfirmed["volume_serial"] == legacy["sources"][1]["volume_serial"]
                and unconfirmed["file_index"] == legacy["sources"][1]["file_index"], "confirming one grant laundered the other legacy identity")
        require(document_state(runtime) == before["document"] and history_bytes(data) == before["history"]
                and library_bytes(data) == before["library"], "confirmation reconnected library IDs or edited the existing work")
        require(source_read(runtime, "external://1", digest) == content
                and source_read(runtime, "library://1") == content, "confirmed authorization did not restore raw/current reads")
        source_read(runtime, "external://2", expected=LEGACY_UNVERIFIED)
        runtime.legacy("asset.open", "library://2", INVALID_STATE)
        successful = auth_path(data).read_bytes()
    finally:
        runtime.close()

    runtime = AsyncNative(library, resource, data, evidence)
    try:
        require(auth_path(data).read_bytes() == successful, "restart rewrote or lost the confirmed/mixed identities")
        require(source_read(runtime, "external://1", digest) == content and source_read(runtime, "library://1") == content,
                "confirmed raw/current Source did not survive restart")
        source_read(runtime, "external://2", expected=LEGACY_UNVERIFIED)
        evidence["confirmed_migration"] = {"confirmed": entry_for(data, 1), "still_legacy": entry_for(data, 2)}
        evidence["checks"].append("explicit_confirmation_preserves_grant_and_library_IDs_restores_current_raw_reads_and_survives_restart")

        before = unchanged_state(runtime)
        runtime.legacy("source.reauthorize", confirmation(1, digest, source))
        runtime.legacy("source.reauthorize", confirmation(1, digest, source))
        require(unchanged_state(runtime) == before, "same identity/hash confirmation was not a byte-preserving noop")
        third = check_root(root / "new verified third source.png")
        third.write_bytes(content)
        import_source(runtime, third)
        assert_real_entry(entry_for(data, 3), win_identity(third))
        require(entry_for(data, 2) == unconfirmed, "saving mixed v2 grants implicitly verified or rewrote the legacy raw evidence")
        replacement = check_root(root / "legacy confirmed replacement.png")
        replacement.write_bytes(content)
        replacement_identity = win_identity(replacement)
        require(replacement_identity["file_index"] != observed[1]["file_index"], "confirmed replacement has the same physical identity")
        os.replace(replacement, source)
        before_replace_confirmation = unchanged_state(runtime)
        runtime.legacy("source.reauthorize", confirmation(1, digest, source), INVALID_STATE)
        source_read(runtime, "external://1", expected=FAILED)
        require(unchanged_state(runtime) == before_replace_confirmation,
                "an old successful confirmation was reused to authorize a replacement file")
        require(source_read(runtime, "library://1", digest) == content, "replacement damaged the independent retained version")
        evidence["mixed_and_repeat"] = {"unchanged_legacy": unconfirmed, "verified_third": entry_for(data, 3),
                                         "replacement_identity": replacement_identity}
        evidence["checks"].append("confirmation_retries_are_noops_mixed_saves_preserve_other_legacy_records_and_verified_replacement_stays_rejected")
    finally:
        runtime.close()


def host_identity_case(console, root, evidence):
    data, source = root / "legacy identity Host data", check_root(root / "Host legacy source with spaces.png")
    content, client = tiny_png(COLOR), (0xC2A0, 0xC2A1)
    source.write_bytes(content)
    digest, observed = sha256(source), win_identity(source)
    stopped = True
    try:
        _, status = invoke(console, "status", data, "portable")
        require(status["state"] == "unreachable", "owned identity Host case already has an active instance")
        _, status = invoke(console, "start", data, "portable")
        stopped = False
        require(status["state"] == "running", "identity Host did not start")
        wire = Workspace(data, evidence)
        status, handle, payload = host_rpc(wire, 16, str(source).encode("utf-8"))
        require(status == ACCEPTED and handle > 0 and not payload, "Host could not import its synthetic Source")
        inserted = wire.submit(wire.request(client, 1, wire.snapshot()["stamp"], "editor.asset.insert", str(handle)))
        require(inserted["status"] == OK, "Host did not adopt its synthetic Source")
        host_legacy(wire, "doc.save", "session://Host-legacy-work.cut")
        _, status = invoke(console, "stop", data, "portable")
        require(status["state"] == "stopped", "fixture Host did not stop")
        stopped = True
        raw, legacy = legacy_fixture(data, {1: observed}, root / "Host-legacy-raw-input.json")
        _, status = invoke(console, "start", data, "portable")
        stopped = False
        require(status["state"] == "running", "Host could not recover a legacy authorization catalog")
        before, old_history, old_library = wire.snapshot(), history_bytes(data), library_bytes(data)
        host_source_read(wire, "external://1", expected=LEGACY_UNVERIFIED)
        host_legacy(wire, "asset.open", "library://1", INVALID_STATE)
        require(host_source_read(wire, "library://1", digest) == content and auth_path(data).read_bytes() == raw,
                "Host implicitly confirmed legacy raw authority or refused its retained version")
        accepted = wire.submit(wire.request((0xC2A2, 0xC2A3), 1, before["stamp"], "editor.export.png", "session://exports/Host-legacy-retained.png"))
        require(accepted["status"] == ACCEPTED, "legacy Host did not admit retained work")
        target = data / "exports/Host-legacy-retained.png"
        wait_host_file(wire, target)
        completed = wait_host_terminal(wire, accepted["task_id"])
        output = assert_output(completed, target, COLOR)
        host_legacy(wire, "source.reauthorize", confirmation(1, digest, source))
        assert_real_entry(entry_for(data, 1), observed)
        require(host_source_read(wire, "external://1", digest) == content
                and host_source_read(wire, "library://1") == content and wire.snapshot() == before
                and history_bytes(data) == old_history and library_bytes(data) == old_library,
                "Host confirmation changed the work/library or failed to restore exact raw/current reads")
        confirmed = auth_path(data).read_bytes()
        host_legacy(wire, "source.reauthorize", confirmation(1, digest, source))
        require(auth_path(data).read_bytes() == confirmed, "Host duplicate confirmation rewrote its catalog")
        _, status = invoke(console, "stop", data, "portable")
        require(status["state"] == "stopped", "confirmed Host did not stop")
        stopped = True
        _, status = invoke(console, "start", data, "portable")
        stopped = False
        require(status["state"] == "running" and not host_listing(wire), "confirmed Host did not restart with an empty Station")
        require(host_source_read(wire, "external://1", digest) == content and auth_path(data).read_bytes() == confirmed,
                "Host restart did not preserve explicit verified identity")
        evidence["Host_identity"] = {"legacy_raw": legacy, "confirmed": entry_for(data, 1), "retained_export": output,
                                      "shell_attached": False}
        evidence["checks"].append("real_Host_RPC_denies_legacy_then_explicit_confirmation_restores_exact_bytes_without_editing_work")
    finally:
        if not stopped:
            _, status = invoke(console, "stop", data, "portable")
            require(status["state"] == "stopped", "owned identity Host cleanup failed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("source-identity"))
    args = parser.parse_args()
    require(os.name == "nt", "real Win32 identity verification requires Windows")
    root = claim(args.root)
    portable = (OUTPUT / "portable").resolve()
    resource, before = portable / "runtime", hashes(portable)
    evidence = {"format": "cutrans-source-identity-verification/1", "root": str(root), "artifact_hashes": before,
        "checks": [], "passed": False,
        "limits": ["C2a fixes physical identity and explicit legacy confirmation, not resource CAS, relink or adopt",
                   "Only synthetic files in this owned case are inspected or atomically replaced; legacy raw evidence is retained",
                   "This does not test GUI, installation, system registration, long-running external writers or arbitrary filesystem races"]}
    try:
        library = ctypes.WinDLL(str(resource / "cutrans_vm_runtime.dll"))
        configure(library)
        require(library.cutrans_vm_abi_version() == identity()["host_api"], "Runtime ABI differs from product identity")
        real_identity_cases(library, resource, root, evidence)
        atomic_replacement_case(library, resource, root, evidence)
        legacy_migration_cases(library, resource, root, evidence)
        host_identity_case(portable / "cutrans_vm.exe", root, evidence)
        require(hashes(portable) == before and not (portable / "data").exists(), "identity verification changed the tested artifact")
        evidence["passed"] = True
        print(f"CUTRANS_SOURCE_IDENTITY_VERIFY_OK checks={len(evidence['checks'])} evidence={root}")
    except BaseException as error:
        evidence["error"] = repr(error)
        raise
    finally:
        evidence["artifact_hashes_after"] = hashes(portable)
        (root / "report.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        retain(root)


if __name__ == "__main__":
    main()
