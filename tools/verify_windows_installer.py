"""Installer artifact probes are registration-free; system tests require a separate OS identity."""
from __future__ import annotations
import argparse
import contextlib
import ctypes
import hashlib
import json
import msvcrt
import os
import re
import subprocess
import sys
import tempfile
import uuid
import winreg
from pathlib import Path

import automation_process
from build_paths import OUTPUT
from product import identity
from verification_paths import default_root, claim, retain
from verification_context import command_args

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = identity()
APP_ID = PRODUCT["app_id"]
EXTENSION_KEY = "Software\\Classes\\" + PRODUCT["document_extension"]
PROGID_KEY = "Software\\Classes\\" + PRODUCT["document_progid"]
COMMAND_KEY = PROGID_KEY + "\\shell\\open\\command"
UNINSTALL_KEY = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\" + APP_ID + "_is1"


@contextlib.contextmanager
def installer_verification_lock():
    path = Path(tempfile.gettempdir()) / (PRODUCT["id"] + "-installer-verification.lock")
    with path.open("a+b") as lock:
        lock.seek(0, 2)
        if lock.tell() == 0:
            lock.write(b"0"); lock.flush()
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as error:
            raise RuntimeError("another installer verification is already running") from error
        try:
            yield
        finally:
            lock.seek(0); msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)


def registry_value(root, key: str):
    try:
        with winreg.OpenKey(root, key) as handle:
            return winreg.QueryValueEx(handle, None)[0]
    except FileNotFoundError:
        return None


def registry_key_exists(root, key: str) -> bool:
    try:
        with winreg.OpenKey(root, key): return True
    except FileNotFoundError:
        return False


def hashes(root: Path, ignored: set[str] | None = None) -> dict[str, str]:
    ignored = ignored or set()
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file() and p.relative_to(root).as_posix() not in ignored}


def system_executable(name: str) -> str:
    buffer = ctypes.create_unicode_buffer(32768)
    if not ctypes.windll.kernel32.GetSystemDirectoryW(buffer, len(buffer)):
        raise ctypes.WinError()
    return str(Path(buffer.value) / name)


def known_folder(guid: str) -> Path:
    raw = (ctypes.c_ubyte * 16).from_buffer_copy(uuid.UUID(guid).bytes_le)
    output = ctypes.c_wchar_p()
    function = ctypes.windll.shell32.SHGetKnownFolderPath
    function.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_wchar_p)]
    function.restype = ctypes.c_long
    if function(ctypes.byref(raw), 0, None, ctypes.byref(output)) != 0:
        raise RuntimeError("could not read the Windows known folder")
    try: return Path(output.value)
    finally: ctypes.windll.ole32.CoTaskMemFree(output)


def registration_snapshot() -> dict:
    def read(key):
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key) as handle:
                values = []
                for i in range(winreg.QueryInfoKey(handle)[1]):
                    name, value, kind = winreg.EnumValue(handle, i)
                    if isinstance(value, bytes): value = value.hex()
                    values.append([name, value, kind])
                children = {winreg.EnumKey(handle, i): read(key + "\\" + winreg.EnumKey(handle, i))
                            for i in range(winreg.QueryInfoKey(handle)[0])}
                return {"values": values, "children": children}
        except FileNotFoundError: return None
    registry = {key: read(key) for key in (EXTENSION_KEY, PROGID_KEY, UNINSTALL_KEY)}
    # Read only product-named links; never enumerate another product's config.
    shortcuts = {}
    for folder in (known_folder("a77f5d77-2e2b-44c3-a6a2-aba601054a51"),
                   known_folder("b4bfcc3a-db2c-424c-b029-7fe99a87c641")):
        for name in (PRODUCT["name"] + ".lnk", "Cutrans 资源库 (NanoUI).lnk"):
            path = folder / name
            shortcuts[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    return {"registry": registry, "shortcuts": shortcuts}


def snapshot_digest(value: dict) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    result = automation_process.run(command_args(command), capture_output=True, text=True,
                            env=dict(os.environ, MSYS2_ARG_CONV_EXCL="*"), timeout=180)
    if result.stdout: print(result.stdout, end="")
    if result.stderr: print(result.stderr, end="")
    return result


def verify_installer_contract() -> None:
    script = (ROOT / "packaging/windows/installer.iss").read_text(encoding="utf-8")
    required = ("#include ProductConfigFile", "AppId={#ProductAppId}", "AppVersion={#ProductVersion}",
                "PrivilegesRequired=lowest", "DisableProgramGroupPage=yes", "DisableReadyPage=yes",
                'MessagesFile: "compiler:Languages\\ChineseSimplified.isl"',
                'Parameters: "desktop --mode=installed"', "CUTRANS_INSTALL_PREFLIGHT_ONLY_OK",
                "CUTRANS_UPGRADE_REJECTED", "OwnsRegistration", "BackupSystemState", "SafeParents",
                "Source: \"{#InstalledContextFile}\"", "CloseApplications=no")
    missing = [entry for entry in required if entry not in script]
    forbidden = [entry for entry in ("PrivilegesRequiredOverridesAllowed", "LicenseFile=", "DisableWelcomePage=yes") if entry in script]
    icons = script.split("[Icons]", 1)[1].split("[InstallDelete]", 1)[0]
    if icons.count('Name: "{autoprograms}\\{#ProductName}"') != 1:
        raise RuntimeError("installer must expose exactly one product entry")
    if missing or forbidden:
        raise RuntimeError(f"installer contract drift: missing={missing}, forbidden={forbidden}")
    print("CUTRANS_INSTALLER_CONTRACT_OK identity=central context=installed diagnostic=temporary upgrade=fail_closed single_entry=1")


def _artifact_probe(installer: Path, root: Path, extra: list[str], marker: str, label: str) -> None:
    log = root / (label + ".log")
    target = root / (label + " target")
    result = run([str(installer), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART",
                  "/PreflightOnly=1", f"/DIR={target}", f"/LOG={log}", *extra])
    output = log.read_text(encoding="utf-8-sig", errors="replace") if log.exists() else ""
    if result.returncode != 7 or marker not in output:
        raise RuntimeError(f"installer preflight probe {label} did not stop before installation; exit={result.returncode}")
    if target.exists():
        raise RuntimeError(f"preflight probe created a destination installation: {target}")


def artifact_check(installer: Path, root: Path, expected: str | None) -> None:
    verify_installer_contract()
    root = claim(root)
    before = hashlib.sha256(installer.read_bytes()).hexdigest()
    if expected is not None and before != expected:
        raise RuntimeError("installer differs from the exact expected artifact hash")
    state = registration_snapshot()
    (root / "system-before.sha256").write_text(snapshot_digest(state) + "\n", encoding="ascii")
    try:
        _artifact_probe(installer, root, [], "CUTRANS_INSTALL_PREFLIGHT_ONLY_OK", "valid")
        _artifact_probe(installer, root, [f"/VerifyDataDir={root / 'forbidden data'}"],
                        "CUTRANS_INSTALL_REJECTED phase=diagnostic-data-override", "override")
        after = hashlib.sha256(installer.read_bytes()).hexdigest()
        current = registration_snapshot()
        if state != current:
            raise RuntimeError("registration-free probe changed system registration or product shortcuts; evidence retained")
        if after != before:
            raise RuntimeError("installer artifact changed during acceptance")
        report = {"format": "cutrans-installer-acceptance/1", "product": PRODUCT["id"],
                  "version": PRODUCT["version"], "sha256": before, "byteLength": installer.stat().st_size,
                  "registration": "untouched", "preflight_only_exit": 7,
                  "system_install_update_uninstall": "not_run"}
        (root / "artifact-acceptance.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("CUTRANS_INSTALLER_ARTIFACT_OK preflight=1 override_rejected=1 registration_untouched=1 sha256=" + before)
    finally:
        retain(root)


def isolated_os_identity(proof: Path | None) -> None:
    if proof is None:
        raise RuntimeError("system registration requires an independent OS user/VM proof; HOME overrides are not isolation")
    data = json.loads(proof.read_text(encoding="utf-8"))
    output = automation_process.check_output([system_executable("whoami.exe"), "/user", "/fo", "csv", "/nh"], text=True)
    sid = output.strip().split(",")[-1].strip('"')
    if data.get("format") != "cutrans-registration-isolation/1" or data.get("product") != PRODUCT["id"] or data.get("operator_approved") is not True:
        raise RuntimeError("invalid independently supplied registration isolation proof")
    if data.get("kind") not in {"separate-os-user", "virtual-machine"}:
        raise RuntimeError("only a separate OS account or VM is accepted")
    for key in ("isolated_user_sid", "production_user_sid"):
        if not isinstance(data.get(key), str) or re.fullmatch(r"S-1-\d+(?:-\d+)+", data[key]) is None:
            raise RuntimeError(f"registration isolation proof requires an explicit valid {key}")
    if sid != data.get("isolated_user_sid") or sid == data.get("production_user_sid"):
        raise RuntimeError("current OS identity is not isolated from the production user")


def system_check(installer: Path, root: Path, proof: Path | None) -> None:
    # Intentionally never auto-run a stale uninstaller on failure. A failed case
    # and its own registration are left in the isolated OS account for review.
    isolated_os_identity(proof)
    snapshot = registration_snapshot()
    if any(value is not None for value in snapshot["registry"].values()) or any(snapshot["shortcuts"].values()):
        raise RuntimeError("isolated account contains existing product registration/links; preserve and inspect separately")
    root = claim(root)
    app = root / "installed app"
    digest = hashlib.sha256(installer.read_bytes()).hexdigest()
    command = [str(installer), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", f"/DIR={app}"]
    try:
        result = run([*command, f"/LOG={root / 'install.log'}"])
        if result.returncode: raise RuntimeError("isolated installation failed; state retained, no automatic uninstall attempted")
        expected = f'"{app / "app/cutrans_vm.exe"}" desktop --mode=installed --open "%1"'
        if registry_value(winreg.HKEY_CURRENT_USER, COMMAND_KEY) != expected:
            raise RuntimeError("installed association does not point at the exact installed root")
        data = app / "data"
        # A normal installed Session must be created through the real entry
        # point before adding synthetic work. An arbitrary nonempty directory
        # is intentionally not accepted as legacy user data.
        console = app / "app/cutrans_vm.exe"
        normal = ["--mode=installed", "--purpose=normal", f"--data={data}"]
        result = run([str(console), "start", *normal])
        if result.returncode:
            raise RuntimeError("isolated installed Host could not create its normal Session")
        result = run([str(console), "stop", *normal])
        if result.returncode:
            raise RuntimeError("isolated installed Host could not save its normal Session")
        sentinel = data / "user-work-sentinel.bin"
        sentinel.write_bytes(b"preserve this synthetic user work across a same-payload reinstall")
        before = hashes(data)
        result = run([*command, f"/LOG={root / 'same-payload-reinstall.log'}"])
        if result.returncode or hashes(data) != before:
            raise RuntimeError("same-payload reinstall failed or changed synthetic user data")
        if hashlib.sha256(installer.read_bytes()).hexdigest() != digest:
            raise RuntimeError("installer changed between install and reinstall")
        uninstaller = app / "unins000.exe"
        result = run([str(uninstaller), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", f"/LOG={root / 'uninstall.log'}"])
        if result.returncode or hashes(data) != before:
            raise RuntimeError("owned uninstaller failed or changed synthetic user data")
        if registry_key_exists(winreg.HKEY_CURRENT_USER, UNINSTALL_KEY):
            raise RuntimeError("owned uninstall registration remains")
        print("CUTRANS_INSTALL_VERIFY_OK independent_os_identity=1 install=1 same_payload_reinstall=1 uninstall=1 changed_payload_upgrade=not_supported")
    finally:
        retain(root)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    name = PRODUCT["name"] + "-Setup-" + PRODUCT["version"] + "-windows-x64.exe"
    parser.add_argument("--installer", type=Path, default=OUTPUT / "installer" / name)
    parser.add_argument("--root", type=Path, default=default_root("windows-installer"))
    parser.add_argument("--artifact-check", action="store_true")
    parser.add_argument("--check-contract", action="store_true")
    parser.add_argument("--expected-sha256")
    parser.add_argument("--system-registration", action="store_true")
    parser.add_argument("--isolation-proof", type=Path)
    parser.add_argument("--skip-gui", action="store_true", help="accepted for old build targets; never authorizes registration")
    args = parser.parse_args()
    if args.check_contract:
        verify_installer_contract(); return
    if not args.artifact_check and not args.system_registration:
        raise RuntimeError("system registration tests are disabled by default; use --artifact-check, or an independent OS account/VM with --system-registration --isolation-proof")
    installer = args.installer.resolve()
    if not installer.is_file(): raise RuntimeError("build the exact installer artifact before acceptance")
    with installer_verification_lock():
        if args.artifact_check:
            artifact_check(installer, args.root, args.expected_sha256)
        else:
            system_check(installer, args.root, args.isolation_proof)


if __name__ == "__main__":
    main()
