"""Exercise Windows packaging with real PE files and an isolated runtime PATH."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

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

    @unittest.skipUnless(os.name == "nt", "PE imports and runtime loading require Windows")
    def test_pe_import_closure_runs_after_relocation_without_system_dll_copies(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            staged = root / "Original"
            staged.mkdir()
            executable = staged / "python.exe"
            packaging.run("llvm-objcopy", "--subsystem=windows", sys.executable, executable)
            self.assertIn("IMAGE_SUBSYSTEM_WINDOWS_GUI", packaging.run("llvm-readobj", "--file-headers", executable))
            packaging.bundle_dependencies(staged, [executable], [Path(sys.executable).parent])
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
