"""Toolchain restore failures must not overwrite a working toolchain."""

import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

import bootstrap


class ToolchainRestoreTests(unittest.TestCase):
    def archive(self, root, extra=None):
        archive = root / "toolchain.zip"
        files = {"zig.exe": b"test-compiler", "lib/std/std.zig": b"std", "lib/compiler_rt.zig": b"runtime"}
        files.update(extra or {})
        with zipfile.ZipFile(archive, "w") as output:
            for name, value in files.items():
                output.writestr("zig-x86_64-windows-0.17.0/" + name, value)
        return archive

    def test_restore_and_reuse_matching_compiler_and_lib(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.archive(root)
            with patch.object(bootstrap, "ZIG_EXE_SHA256", bootstrap.sha256(b"test-compiler")):
                bootstrap.install_zig(archive, False, root)
                bootstrap.install_zig(archive, False, root)
            self.assertEqual((root / "tools/zig/lib/std/std.zig").read_bytes(), b"std")
            self.assertTrue((root / "tools/zig/.cutrans-toolchain.json").is_file())

    def test_drift_is_rejected_before_any_missing_file_is_restored(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compiler = root / "tools/zig/zig.exe"
            compiler.parent.mkdir(parents=True)
            compiler.write_bytes(b"local-change")
            archive = self.archive(root)
            with patch.object(bootstrap, "ZIG_EXE_SHA256", bootstrap.sha256(b"test-compiler")):
                with self.assertRaisesRegex(RuntimeError, "existing toolchain file differs"):
                    bootstrap.install_zig(archive, False, root)
            self.assertEqual(compiler.read_bytes(), b"local-change")
            self.assertFalse((root / "tools/zig/lib/std/std.zig").exists())

    def test_traversal_is_rejected_without_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.archive(root, {"../outside": b"bad"})
            with self.assertRaisesRegex(RuntimeError, "unsafe toolchain"):
                bootstrap.install_zig(archive, False, root)
            self.assertFalse((root / "tools/zig").exists())

    def test_http_package_hash_is_checked_against_nanoui_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(bootstrap.automation_process, "run_console_tree", return_value=SimpleNamespace(stdout="wrong-hash\n")):
                with self.assertRaisesRegex(RuntimeError, "canonical package hash mismatch"):
                    bootstrap.install_http(root / "http.tar.gz", root)


if __name__ == "__main__":
    unittest.main()
