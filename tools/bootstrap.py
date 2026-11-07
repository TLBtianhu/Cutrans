"""Restore a complete pinned toolchain and native libraries outside source control."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tarfile
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path
from pathlib import PurePosixPath

import automation_process

ROOT = Path(__file__).resolve().parents[1]

ZIG_URL = "https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip"
ZIG_ARCHIVE_SHA256 = "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428"
ZIG_EXE_SHA256 = "f54b14f02a4d7d8ac62a94a0663486eb166bba3745d85b466238c1b93e723d46"

WGPU_URL = "https://github.com/gfx-rs/wgpu-native/releases/download/v29.0.1.1/wgpu-windows-x86_64-msvc-release.zip"
WGPU_ARCHIVE_SHA256 = "7e67d7445c42aeb85e30f88930fd8d7d83ee769e3390aeb1ada75ebf3cf78132"
WGPU_FILES = {
    "wgpu_native.dll": "5e26249c40dcdac43f5adca3195fcf40e4ec6c67472b38510165f411fcc198e7",
    "wgpu_native.dll.lib": "261adb64aef86a3ebaf7f6f370d14bed083f93e25e2eec70a7c54d33954e4572",
    "wgpu_native.lib": "c47ed51546823c02c6d33e24a58e62e0535442ca1897a17d2305b2e55df35729",
    "wgpu_native.pdb": "90adf1ec5a8e1c518be4b0bf213c1ed21f066fdfd57d768aa16ed4e89d868160",
}

DXGUID_URL = "https://raw.githubusercontent.com/zig-gamedev/system_sdk/beb29112ae93b3f7ef0140be0c9f340b1145f5c9/windows/lib/x86_64-windows-gnu/dxguid.lib"
DXGUID_SHA256 = "f5c539bba43b412d13f112dc76164d60cf9c0f13732b95d13b9d87a07eeedb5a"

HTTP_COMMIT = "1f798e762f52ff81cc6c370b4f322c9e65064462"
HTTP_URL = f"https://codeload.github.com/justrach/http-zig/tar.gz/{HTTP_COMMIT}"
HTTP_ARCHIVE_SHA256 = "36d696751bf9662d409fd8767d6617027bc322f9eabdbdf72d615de109499bcc"
HTTP_PACKAGE_HASH = "http_zig-0.1.0-2CB7E00SAwAnwnBkJDgCDm3zLwrCmZZkHNSw5t7X9Vbf"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def download(url: str, expected_sha256: str, destination: Path, opener) -> Path:
    if destination.is_file() and sha256(destination.read_bytes()) == expected_sha256:
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(1, 4):
        try:
            digest = hashlib.sha256()
            with opener.open(urllib.request.Request(url, headers={"User-Agent": "Cutrans-bootstrap/0.1"}), timeout=90) as response:
                with destination.open("wb") as output:
                    while chunk := response.read(1024 * 1024):
                        digest.update(chunk)
                        output.write(chunk)
            if digest.hexdigest() != expected_sha256:
                raise RuntimeError(f"archive hash mismatch: {url}")
            return destination
        except Exception:
            if attempt == 3:
                raise
            time.sleep(attempt)
    raise AssertionError("unreachable")


def install_bytes(relative: str, data: bytes, expected_sha256: str, force: bool) -> None:
    if sha256(data) != expected_sha256:
        raise RuntimeError(f"content hash mismatch: {relative}")
    target = ROOT / relative
    if target.is_file():
        if sha256(target.read_bytes()) == expected_sha256:
            print(f"present {relative}")
            return
        if not force:
            raise RuntimeError(f"existing file differs; rerun with --force to replace: {relative}")
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + ".bootstrap-tmp")
    temporary.write_bytes(data)
    temporary.replace(target)
    print(f"installed {relative}")


def install_zig(archive_path: Path, force: bool, root: Path = ROOT) -> None:
    """Validate every destination before restoring compiler and matching lib together."""
    prefix = "zig-x86_64-windows-0.17.0/"
    target_root = (root / "tools/zig").resolve()
    with zipfile.ZipFile(archive_path) as archive:
        members = []
        seen = set()
        for member in archive.infolist():
            if member.is_dir():
                continue
            if not member.filename.startswith(prefix):
                raise RuntimeError("unexpected toolchain archive root")
            relative = PurePosixPath(member.filename[len(prefix):])
            if relative.is_absolute() or ".." in relative.parts or "\\" in str(relative) or ":" in str(relative):
                raise RuntimeError("unsafe toolchain archive path")
            target = (target_root / str(relative)).resolve()
            if not target.is_relative_to(target_root) or target == target_root:
                raise RuntimeError("toolchain archive escapes its destination")
            if str(relative).casefold() in seen:
                raise RuntimeError("duplicate toolchain archive path")
            seen.add(str(relative).casefold())
            members.append((member, target))
        if not {"zig.exe", "lib/std/std.zig", "lib/compiler_rt.zig"}.issubset(seen):
            raise RuntimeError("incomplete Zig toolchain archive")
        changed = []
        for member, target in members:
            expected = sha256(archive.read(member))
            if target.name == "zig.exe" and expected != ZIG_EXE_SHA256:
                raise RuntimeError("Zig compiler hash mismatch")
            if target.exists():
                if not target.is_file():
                    raise RuntimeError(f"toolchain destination is not a file: {target}")
                if sha256(target.read_bytes()) == expected:
                    continue
                if not force:
                    raise RuntimeError(f"existing toolchain file differs: {target}; use --force to replace")
            changed.append((member, target))
        # Put the compiler last: lib is restored before a new compiler becomes usable.
        changed.sort(key=lambda item: item[1].name == "zig.exe")
        for member, target in changed:
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name(target.name + ".bootstrap-tmp")
            temporary.write_bytes(archive.read(member))
            temporary.replace(target)
        marker = target_root / ".cutrans-toolchain.json"
        marker.write_text(json.dumps({"version": "0.17.0", "archive_sha256": ZIG_ARCHIVE_SHA256,
                                      "files": len(members)}, indent=2) + "\n", encoding="utf-8")
    print(f"Zig 0.17.0 compiler + lib verified: {len(members)} files, restored={len(changed)}")


def install_http(archive_path: Path, root: Path = ROOT, zig_exe: Path | None = None, force: bool = False) -> None:
    """Let Zig verify the canonical package hash without Git's remote transport."""
    environment = os.environ.copy()
    environment["ZIG_GLOBAL_CACHE_DIR"] = str(root / ".zig-cache/global")
    result = automation_process.run_console_tree(
        [str(zig_exe or root / "tools/zig/zig.exe"), "fetch", "--pkg-dir",
         str(root / "zig-pkg"), str(archive_path.resolve())],
        cwd=root, env=environment, check=True, capture_output=True, text=True,
    )
    if result.stdout.strip() != HTTP_PACKAGE_HASH:
        raise RuntimeError("http-zig canonical package hash mismatch")
    # Publish the verified source into the local package cache too. A developer's
    # later build may select a different global compiler cache from bootstrap.
    destination = (root / "zig-pkg" / HTTP_PACKAGE_HASH).resolve()
    with tarfile.open(archive_path, "r:gz") as archive:
        files = []
        prefix = f"http-zig-{HTTP_COMMIT}/"
        for member in archive.getmembers():
            if member.isdir():
                continue
            if not member.isfile() or not member.name.startswith(prefix):
                raise RuntimeError("unexpected http-zig archive member")
            relative = PurePosixPath(member.name[len(prefix):])
            target = (destination / str(relative)).resolve()
            if relative.is_absolute() or ".." in relative.parts or ":" in str(relative) or "\\" in str(relative) or not target.is_relative_to(destination):
                raise RuntimeError("unsafe http-zig archive path")
            content = archive.extractfile(member).read()
            if target.exists() and target.read_bytes() != content and not force:
                raise RuntimeError(f"existing http-zig source differs: {target}; use --force to replace")
            files.append((target, content))
        for target, content in files:
            if target.is_file() and target.read_bytes() == content:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name(target.name + ".bootstrap-tmp")
            temporary.write_bytes(content)
            temporary.replace(target)
    print(f"http-zig archive and Zig package hash verified: {HTTP_COMMIT}")


INNO_URL = "https://github.com/jrsoftware/issrc/releases/download/is-7_1_1/innosetup-7.1.1-x64.exe"
INNO_SHA256 = "8a5a6711c3766a6e5fb74f280ba0e3551e719ce94538d901fdbd1f8f9920b3f0"


def check_inno_version(exe: Path) -> None:
    result = automation_process.run([str(exe), "--version"], check=True, capture_output=True, text=True)
    if "7.1.1" not in result.stdout:
        raise RuntimeError("existing Inno Setup has an unexpected version; rerun with --force to replace it")


def install_inno(work: Path, opener, force: bool) -> None:
    exe = ROOT / "tools/InnoSetup/ISCC.exe"
    if exe.is_file() and not force:
        check_inno_version(exe)
        print("present tools/InnoSetup/ISCC.exe")
        return
    installer = download(INNO_URL, INNO_SHA256, work / "innosetup.exe", opener)
    automation_process.run(
        [
            str(installer),
            "/VERYSILENT",
            "/SUPPRESSMSGBOXES",
            "/NORESTART",
            "/CURRENTUSER",
            "/PORTABLE=1",
            f"/DIR={exe.parent}",
        ],
        check=True,
    )
    check_inno_version(exe)
    print("installed tools/InnoSetup (portable, pinned installer SHA-256)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proxy", help="optional HTTP/HTTPS proxy, for example http://127.0.0.1:7897")
    parser.add_argument("--force", action="store_true", help="replace existing files whose hashes differ")
    parser.add_argument("--installer-tool", action="store_true", help="restore portable Inno Setup for the installer build")
    args = parser.parse_args()
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": args.proxy, "https": args.proxy}) if args.proxy else urllib.request.ProxyHandler()
    )

    with tempfile.TemporaryDirectory(prefix="cutrans-bootstrap-") as temporary:
        work = Path(temporary)
        dxguid_relative = "third_party/system_sdk/windows/lib/x86_64-windows-gnu/dxguid.lib"
        dxguid_target = ROOT / dxguid_relative
        if dxguid_target.is_file() and sha256(dxguid_target.read_bytes()) == DXGUID_SHA256:
            print(f"present {dxguid_relative}")
        else:
            dxguid = download(DXGUID_URL, DXGUID_SHA256, work / "dxguid.lib", opener)
            install_bytes(dxguid_relative, dxguid.read_bytes(), DXGUID_SHA256, args.force)

        if all((ROOT / "third_party/wgpu/lib" / name).is_file() and
               sha256((ROOT / "third_party/wgpu/lib" / name).read_bytes()) == expected
               for name, expected in WGPU_FILES.items()):
            print("present wgpu-native v29.0.1.1 (all native file hashes verified)")
        else:
            wgpu_archive = download(WGPU_URL, WGPU_ARCHIVE_SHA256, work / "wgpu.zip", opener)
            with zipfile.ZipFile(wgpu_archive) as archive:
                for name, expected in WGPU_FILES.items():
                    install_bytes(f"third_party/wgpu/lib/{name}", archive.read(f"lib/{name}"), expected, args.force)

        zig_archive = download(ZIG_URL, ZIG_ARCHIVE_SHA256,
                               ROOT / "zig-pkg/bootstrap/zig-0.17.0-windows-x64.zip", opener)
        install_zig(zig_archive, args.force)
        http_archive = download(HTTP_URL, HTTP_ARCHIVE_SHA256,
                                ROOT / f"zig-pkg/bootstrap/http-zig-{HTTP_COMMIT}.tar.gz", opener)
        install_http(http_archive, force=args.force)
        if args.installer_tool:
            install_inno(work, opener, args.force)

    print("Cutrans third-party binaries are ready")


if __name__ == "__main__":
    main()
