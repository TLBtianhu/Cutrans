"""Exercise real distribution entry points with hostile launch inputs; no registration."""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import shutil
from pathlib import Path

import automation_process

from build_paths import ROOT, OUTPUT
from product import identity
from verification_paths import claim, default_root, retain
from verification_context import copy_installed_context

LOG = None


def hashes(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file()}


def run(args, *, cwd=None, env=None, expected=0):
    runner = automation_process.run_console_tree if Path(args[0]).resolve() == (ROOT / "tools/zig/zig.exe").resolve() else automation_process.run
    result = runner([str(v) for v in args], cwd=cwd, env=env, capture_output=True, text=True, timeout=60)
    output = result.stdout + result.stderr
    if LOG is not None:
        with LOG.open("a", encoding="utf-8") as evidence:
            evidence.write(json.dumps({"command": [str(v) for v in args], "cwd": str(cwd) if cwd else None,
                                       "exit": result.returncode, "output": output}, ensure_ascii=False) + "\n")
    if result.returncode != expected:
        raise RuntimeError(f"exit={result.returncode}, expected={expected}, command={args}\n{output}")
    return output


def context(args, **kwargs):
    output = run(args, **kwargs)
    for line in output.splitlines():
        if line.startswith("CUTRANS_CONTEXT_JSON "):
            return json.loads(line.split(" ", 1)[1])
    raise RuntimeError("missing resolved context report: " + output)


def fixture_identity(path, form, channel):
    path.mkdir(parents=True, exist_ok=False)
    (path / "cutrans-instance.json").write_text(json.dumps({
        "format": "cutrans-instance/1", "product_id": identity()["id"], "form": form,
        "channel": channel, "purpose": "verification",
    }), encoding="utf-8")


def dll_probe(root, probe):
    pack = root / "dll pack"
    poison = root / "dll poison"
    pack.mkdir(); poison.mkdir()
    dep = root / "dep.c"
    dep.write_text("__declspec(dllexport) int cutrans_dep(void) { return VALUE; }\n")
    plugin = root / "plugin.c"
    plugin.write_text("__declspec(dllimport) int cutrans_dep(void); __declspec(dllexport) int cutrans_probe(void) { return cutrans_dep(); }\n")
    zig = ROOT / "tools/zig/zig.exe"
    for folder, value in ((pack, 7), (poison, 99)):
        run([zig, "cc", "-target", "x86_64-windows-gnu", "-shared", dep, f"-DVALUE={value}",
             "-o", folder / "cutrans_fixture_dep.dll", f"-Wl,--out-implib,{folder / 'dep.lib'}"])
    run([zig, "cc", "-target", "x86_64-windows-gnu", "-shared", plugin, pack / "dep.lib", "-o", pack / "plugin.dll"])
    env = os.environ.copy(); env["PATH"] = str(poison) + os.pathsep + env.get("PATH", "")
    if "value=7" not in run([probe, pack / "plugin.dll"], cwd=poison, env=env):
        raise RuntimeError("the verified dependency directory was not selected")
    trusted = (pack / "cutrans_fixture_dep.dll").read_bytes()
    (pack / "cutrans_fixture_dep.dll").unlink()
    output = run([probe, pack / "plugin.dll"], cwd=poison, env=env, expected=1)
    if "LibraryLoadFailed" not in output:
        raise RuntimeError("missing dependency did not fail in the library port")
    (pack / "cutrans_fixture_dep.dll").write_bytes(trusted)
    return "trusted=7 cwd_path_poison=99 missing_pack_dependency=rejected"


def main():
    global LOG
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root("isolation"))
    args = parser.parse_args()
    root = claim(args.root)
    LOG = root / "commands.jsonl"
    checks = []
    before = hashes(OUTPUT / "portable")
    copy = root / "portable copy"
    shutil.copytree(OUTPUT / "portable", copy)
    vm = copy / "cutrans.exe"
    boot = copy / "cutrans_bootstrap.exe"
    diag = copy / "cutrans_diag.exe"
    # One environment instance that only starts and stops; a refused launch
    # fails while resolving its data root, before the script is read.
    noop = root / "noop.jsonl"
    noop.write_text('{"call": "stop"}\n', encoding="utf-8")
    start = ["exec", f"--script={noop}"]
    base = context([vm, "context"])
    cwd = root / "unrelated workspace"; cwd.mkdir()
    (cwd / ".env").write_text("CUTRANS_DATA_DIR=must-not-be-read\nLOCALAPPDATA=must-not-be-read\n")
    env = os.environ.copy()
    for key in ("HOME", "USERPROFILE", "LOCALAPPDATA", "APPDATA", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "CUTRANS_DATA_DIR", "CUTRANS_RUNTIME_DIR", "NANOUI_WEBVIEW_PROFILE"):
        env[key] = str(root / "poison homes" / key)
    for command in ([vm, "context"], [diag, "--inspect"]):
        actual = context(command, cwd=cwd, env=env)
        for field in ("product_id", "version", "channel", "form", "product_root", "resource_dir", "data_dir", "services"):
            if actual[field] != base[field]:
                raise RuntimeError(f"launch inputs changed {field}: {actual[field]} != {base[field]}")
    if (copy / "data").exists() or (cwd / "imgui.ini").exists() or (root / "poison homes").exists():
        raise RuntimeError("read-only inspection created application state")
    checks.append("cwd_env_dotenv_ignored_gui_cli_same_context")
    # A build staging directory is not a user's portable installation.
    out = run([OUTPUT / "portable/cutrans.exe", *start], expected=1)
    if "StagingRequiresExplicitDataDirectory" not in out:
        raise RuntimeError("staging default write did not hit its explicit boundary: " + out)
    forbidden = OUTPUT / "portable" / ("forbidden-data-" + root.name)
    if forbidden.exists(): raise RuntimeError("negative staging data fixture is not new")
    for entry, args in ((OUTPUT / "portable/cutrans.exe", [*start, "--purpose=verification", f"--data={forbidden}"]),
                        (vm, [*start, "--purpose=verification", f"--data={forbidden}"]),
                        (OUTPUT / "portable/cutrans_diag.exe", [f"--verify-data-dir={forbidden}"])):
        if "OverlappingResourceAndDataDirectory" not in run([entry, *args], expected=1):
            raise RuntimeError("an explicit override bypassed disposable staging boundaries")
    if forbidden.exists(): raise RuntimeError("staging rejection created runtime data")
    checks.append("staging_default_and_explicit_data_rejected")
    for reserved in ("assets", "runtime", "payload/desktop", "payload/nanoui-library"):
        forbidden = copy / reserved / "forbidden-verification-data"
        for entry, args in ((vm, [*start, "--purpose=verification", f"--data={forbidden}"]),
                            (diag, [f"--verify-data-dir={forbidden}"])):
            if "OverlappingResourceAndDataDirectory" not in run([entry, *args], expected=1):
                raise RuntimeError("an optional application Pack accepted runtime data: " + reserved)
        if forbidden.exists(): raise RuntimeError("reserved Pack rejection created runtime data")
    checks.append("all_optional_product_pack_data_overrides_rejected")
    installed = root / "installed layout"
    app = installed / "app"
    shutil.copytree(copy, app, ignore=shutil.ignore_patterns("runtime"))
    copy_installed_context(app)
    shutil.copytree(copy / "runtime", installed / "runtime-envs/default")
    installed_before = hashes(installed)
    for reserved in ("app", "app/payload/desktop", "runtime-envs/default"):
        forbidden = installed / reserved / "forbidden-verification-data"
        for entry, args in ((app / "cutrans.exe", [*start, "--purpose=verification", f"--data={forbidden}"]),
                            (app / "cutrans_diag.exe", [f"--verify-data-dir={forbidden}"])):
            if "OverlappingResourceAndDataDirectory" not in run([entry, *args], expected=1):
                raise RuntimeError("installed sibling program directory accepted runtime data: " + reserved)
    alias = root / "payload data junction"
    run(["cmd", "/c", "mklink", "/J", alias, installed / "app/payload/desktop"])
    try:
        output = run([app / "cutrans.exe", *start, "--purpose=verification", f"--data={alias / 'forbidden-verification-data'}"], expected=1)
        if "OverlappingResourceAndDataDirectory" not in output:
            raise RuntimeError("a junction bypassed installed program-data protection: " + output)
    finally: os.rmdir(alias)
    if hashes(installed) != installed_before:
        raise RuntimeError("installed layout negative tests changed program assets")
    checks.append("installed_sibling_pack_and_junction_overrides_rejected")
    if "VerificationRequiresExplicitDataDirectory" not in run([diag], cwd=cwd, env=env, expected=1):
        raise RuntimeError("a writable diagnostic did not require an explicit verification root")
    source = root / "original.cut"
    original = (copy / "assets/examples/minimal.cut").read_bytes()
    source.write_bytes(original.replace(b"0.8", b"0.3"))
    source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    result = run([diag, f"--verify-data-dir={root / 'diagnostic data'}", f"--open={source}"], cwd=cwd, env=env)
    if "CUTRANS_DIAG_OK" not in result or hashlib.sha256(source.read_bytes()).hexdigest() != source_hash:
        raise RuntimeError("diagnostic round trip changed its external original")
    if hashes(copy) != before:
        raise RuntimeError("diagnostic modified distribution files")
    checks.append("diagnostic_original_and_pack_unchanged")
    data = root / "environment data"
    command = lambda action, *extra: [vm, action, "--purpose=verification", f"--data={data}", *extra]
    run([vm, *start, "--purpose=verification", f"--data={data}"], cwd=cwd, env=env)
    first = run(command("status"))
    alias = str(data).upper() + "\\..\\environment data"
    aliased = run([vm, "status", "--purpose=verification", f"--data={alias}"])
    if "state=stopped" not in first or first != aliased:
        raise RuntimeError("case/dot aliases split instance identity")
    rejected = run([vm, *start, "--purpose=normal", f"--data={data}"], expected=1)
    if "InstanceIdentityMismatch" not in rejected:
        raise RuntimeError("another purpose could adopt verification state")
    # The read-only destination is refused after the App precheck and before any window.
    lock_before = (data / "session/runtime.lock").read_bytes()
    readonly = run([vm, "--purpose=verification", f"--data={data}", "--record-input=pack://forbidden.cvr"], expected=1)
    if "CUTRANS_SHELL_PRECHECK_OK" not in readonly or "InputRecordStartFailed" not in readonly:
        raise RuntimeError("the desktop entry did not reach its App precheck before refusing the recording")
    if (data / "session/runtime.lock").read_bytes() != lock_before:
        raise RuntimeError("a failed front end changed the committed selection")
    checks.append("canonical_identity_purpose_conflict_front_end_failure_preserves_lock")
    # Activate a different verified Runtime without running the editing probe.
    # A failed candidate preserves both the selection and the saved Session.
    selected_lock = data / "session/runtime.lock"
    old_selection = selected_lock.read_bytes()
    saved_state = hashes(data)
    saved_state.pop("session/runtime.lock")
    candidate = root / "runtime activation candidate"
    shutil.copytree(copy / "runtime", candidate)
    candidate_manifest = candidate / "runtime-pack.json"
    candidate_record = json.loads(candidate_manifest.read_text(encoding="utf-8"))
    candidate_record["version"] += "-isolation-check"
    candidate_manifest.write_text(json.dumps(candidate_record, indent=2) + "\n", encoding="utf-8")
    activation = lambda directory: command("activate-runtime", f"--runtime={directory}")
    if "CUTRANS_RUNTIME_ACTIVATED" not in run(activation(candidate)):
        raise RuntimeError("explicit verified Runtime activation did not complete")
    candidate_selection = selected_lock.read_bytes()
    if candidate_selection == old_selection:
        raise RuntimeError("explicit Runtime activation did not commit the new candidate")
    startup = candidate / "config/startup.ccb"
    startup_bytes = startup.read_bytes(); startup.unlink()
    try:
        failure = run(activation(candidate), expected=1)
        if "FileNotFound" not in failure or selected_lock.read_bytes() != candidate_selection:
            raise RuntimeError("failed Runtime activation changed the committed candidate: " + failure)
    finally: startup.write_bytes(startup_bytes)
    # The Session was created by the single-process environment, whose original
    # selection is the built-in Runtime; roll back to exactly that.
    run(activation("builtin"))
    after_activation = hashes(data); after_activation.pop("session/runtime.lock")
    if selected_lock.read_bytes() != old_selection or after_activation != saved_state:
        changed = sorted(key for key in set(saved_state) | set(after_activation) if saved_state.get(key) != after_activation.get(key))
        raise RuntimeError(f"Runtime retry/rollback changed the saved verification Session: lock_changed={selected_lock.read_bytes() != old_selection} files={changed}")
    checks.append("runtime_activation_candidate_failure_retry_preserves_session")
    # Malformed selection and an unavailable data path fail before committing a candidate.
    corrupt = root / "corrupt lock data"; fixture_identity(corrupt, base["form"], base["channel"])
    (corrupt / "session").mkdir(); lock = corrupt / "session/runtime.lock"; lock.write_bytes(b"invalid-lock")
    corrupt_output = run([vm, "--diag", "--purpose=verification", f"--data={corrupt}"], expected=1)
    if not any(name in corrupt_output for name in ("RuntimeLock", "RuntimeSelection", "InvalidRuntime", "SyntaxError")):
        raise RuntimeError("malformed lock failed for an unlocated reason: " + corrupt_output)
    if lock.read_bytes() != b"invalid-lock": raise RuntimeError("bad selection was overwritten")
    checks.append("corrupt_lock_preserved")
    manifest = copy / "cutrans-context.json"; saved = manifest.read_bytes()
    try:
        manifest.unlink()
        # Since the 2026-11-10 embedded context slice a portable shape without
        # its external file uses the executable's own portable context; it must
        # resolve exactly the same identity, never another form or channel.
        embedded = context([vm, "context"], cwd=cwd, env=env)
        for field in ("product_id", "version", "channel", "form", "product_root", "services"):
            if embedded[field] != base[field]:
                raise RuntimeError(f"embedded context fallback changed {field}: {embedded[field]} != {base[field]}")
        record = json.loads(saved); record["services"]["updates"] = True
        manifest.write_text(json.dumps(record))
        if "UnconfiguredServiceEnabled" not in run([vm, "context"], expected=1):
            raise RuntimeError("unconfigured service was enabled")
    finally: manifest.write_bytes(saved)
    runtime_manifest = copy / "runtime/runtime-pack.json"; saved_runtime = runtime_manifest.read_bytes()
    try:
        runtime_manifest.unlink()
        missing = run([boot, "--diag", "--purpose=verification", f"--data={root / 'missing runtime data'}"], env=env, expected=1)
        if "RuntimePackNotFound" not in missing and "FileNotFound" not in missing:
            raise RuntimeError("missing Runtime failed outside resource resolution: " + missing)
    finally: runtime_manifest.write_bytes(saved_runtime)
    if (root / "poison homes").exists(): raise RuntimeError("a broken pack created a legacy environment home")
    checks.append("broken_context_runtime_and_service_policy_fail_closed")
    # A data root still held by a Host of an older build (its exclusive
    # host.lock) must refuse an environment without committing a selection.
    locked = root / "locked data"; fixture_identity(locked, base["form"], base["channel"])
    (locked / "session").mkdir()
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                                   ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.CreateFileW(str(locked / "session/host.lock"), 0xC0000000, 0, None, 4, 0x80, None)
    if handle in (None, ctypes.c_void_p(-1).value): raise ctypes.WinError(ctypes.get_last_error())
    try:
        output = run([vm, *start, "--purpose=verification", f"--data={locked}"], expected=1)
        if "EnvironmentAlreadyRunning" not in output or (locked / "session/runtime.lock").exists():
            raise RuntimeError("exclusive lock failure changed the selection: " + output)
    finally: kernel.CloseHandle(handle)
    checks.append("legacy_host_lock_blocks_an_environment_without_commit")
    from verification_paths import remove
    target = root / "link target"; target.mkdir(); sentinel = target / "KEEP"; sentinel.write_bytes(b"owned fixture; retain")
    link = root / "junction fixture"
    run(["cmd", "/c", "mklink", "/J", link, target])
    try:
        try: remove(link)
        except RuntimeError: pass
        else: raise RuntimeError("cleanup followed a junction")
        if sentinel.read_bytes() != b"owned fixture; retain": raise RuntimeError("junction target was modified")
    finally:
        # Nonrecursive removal of this exact fixture link; never recurse into its target.
        os.rmdir(link)
    checks.append("junction_cleanup_rejected_target_preserved")
    checks.append(dll_probe(root, OUTPUT / "verification-tools/cutrans_library_probe.exe"))
    if hashes(OUTPUT / "portable") != before:
        raise RuntimeError("verification changed the original packaged artifact")
    report = {"format": "cutrans-isolation-evidence/1", "root": str(root), "checks": checks,
              "portable_files": before, "system_registration": "not performed", "deleted_user_data": []}
    (root / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    retain(root)
    print(f"CUTRANS_ISOLATION_OK checks={len(checks)} original_write=0 pack_unchanged=1 registration=0 evidence={root}")


if __name__ == "__main__":
    main()
