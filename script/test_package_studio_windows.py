"""Exercise Windows packaging with real PE files and an isolated runtime PATH."""
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("package_studio", Path(__file__).with_name("package_studio_windows.py"))
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class WindowsPackagingTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "nt", "Windows packaging requires the Windows Swift toolchain")
    def test_standalone_staging_preserves_an_existing_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            installed = output / "AdaStudio-local-windows-x86_64"
            installed.mkdir()
            marker = installed / "user-file.txt"
            marker.write_text("keep", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                packaging.package(Path("missing"), Path("missing"), output, "local", stage_only=True)
            self.assertEqual(marker.read_text(encoding="utf-8"), "keep")

    def test_version_cannot_escape_output_directory(self):
        for version in ["../escape", "v1/a", "v1\\a", "", "a" * 81]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                packaging.package(Path("missing"), Path("missing"), Path("missing"), version)

    def test_stage_dxc_checks_the_archive_and_preserves_paired_x64_binaries_and_notices(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            staging = root / "staged"
            staging.mkdir()
            archive = root / ".build-tools" / packaging.DXC_ARCHIVE
            archive.parent.mkdir()
            binaries = {"dxcompiler.dll": b"x64-compiler", "dxil.dll": b"x64-validator"}
            notices = ("LICENCE-MIT.txt", "LICENSE-LLVM.txt", "LICENSE-MS.txt")
            with zipfile.ZipFile(archive, "w") as bundle:
                for name, content in binaries.items():
                    bundle.writestr(f"bin/x64/{name}", content)
                    bundle.writestr(f"bin/arm64/{name}", b"arm64")
                for name in notices:
                    bundle.writestr(name, name)
            expected_digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            with patch.object(packaging, "ROOT", root), patch.object(packaging, "DXC_SHA256", expected_digest):
                packaging.stage_dxc(staging)
                for name, expected in binaries.items():
                    self.assertEqual((staging / name).read_bytes(), expected)
                for name in notices:
                    destination = staging / "ThirdPartyNotices" / "DirectXShaderCompiler" / name
                    self.assertEqual(destination.read_text(encoding="utf-8"), name)
                archive.write_bytes(b"corrupt")
                with self.assertRaisesRegex(RuntimeError, "unexpected SHA-256"):
                    packaging.stage_dxc(staging)

    @unittest.skipUnless(os.name == "nt", "PE imports and runtime loading require Windows")
    def test_pe_import_closure_runs_after_relocation_without_system_dll_copies(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            staged = root / "Original"
            staged.mkdir()
            executable = staged / "python.exe"
            # A venv interpreter is a redirector which needs pyvenv.cfg, not a standalone PE fixture.
            python = Path(sys.base_prefix) / "python.exe"
            packaging.run("llvm-objcopy", "--subsystem=windows", python, executable)
            self.assertIn("IMAGE_SUBSYSTEM_WINDOWS_GUI", packaging.run("llvm-readobj", "--file-headers", executable))
            packaging.bundle_dependencies(staged, [executable], [python.parent])
            self.assertFalse((staged / "KERNEL32.dll").exists())
            self.assertFalse((staged / "USER32.dll").exists())
            self.assertTrue(any(staged.glob("python3*.dll")))
            moved = root / "Moved Кириллица & spaces"
            staged.rename(moved)
            result = subprocess.run([str(moved / "python.exe"), "--version"], env=packaging.clean_environment(),
                                    cwd=root, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b"Python", result.stdout)


if __name__ == "__main__":
    unittest.main()
