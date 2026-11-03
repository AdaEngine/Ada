"""Run the Windows installer against real temporary distributions and destinations."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

INSTALLER = Path(__file__).with_name("install_studio_windows.ps1").resolve()


@unittest.skipUnless(os.name == "nt", "Requires Windows PowerShell")
class WindowsInstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ada-install-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "Release [v1] Кириллица & spaces"
        self.destination = self.root / "Programs" / "Ada Studio [test]"
        self.source.mkdir()
        for name in ["AdaEditor.exe", "adastudio.exe"]:
            shutil.copy2(sys.executable, self.source / name)
        # Real native executables, with their runtime beside them, exercise relocation.
        for library in Path(sys.executable).parent.glob("*.dll"):
            shutil.copy2(library, self.source / library.name)
        for relative, content in {
            "BuildSDK/sdk.json": '{"schemaVersion": 1}',
            "AdaEditor_AdaEditor.resources/Assets/marker.txt": "assets",
            "AdaEngine_AdaRender.resources/shader.txt": "shader",
            ".hidden-resource": "hidden",
        }.items():
            file = self.source / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(content, encoding="utf-8")

    def install(self, *extra, expected=0, source=None, destination=None, installer=INSTALLER, environment=None):
        command = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(installer),
                   "-NoShortcut"]
        if source is not False:
            command += ["-SourcePath", str(source or self.source)]
        if destination is not False:
            command += ["-InstallDirectory", str(destination or self.destination)]
        result = subprocess.run(command + list(extra), capture_output=True, timeout=45, env=environment)
        if expected == 0:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_complete_install_and_upgrade_relocates_native_tools(self):
        self.install()
        self.assertEqual((self.destination / ".hidden-resource").read_text(), "hidden")
        self.assertEqual((self.destination / "AdaEditor_AdaEditor.resources/Assets/marker.txt").read_text(), "assets")
        result = subprocess.run([str(self.destination / "adastudio.exe"), "--version"],
                                capture_output=True, timeout=15, cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"Python", result.stdout)
        (self.destination / "obsolete.dll").write_bytes(b"old")
        (self.source / "AdaEngine_AdaRender.resources/shader.txt").write_text("updated")
        self.install()
        self.assertFalse((self.destination / "obsolete.dll").exists())
        self.assertEqual((self.destination / "AdaEngine_AdaRender.resources/shader.txt").read_text(), "updated")
        self.assertEqual(list(self.destination.parent.glob(".ada-studio-*")), [])

    def test_incomplete_source_preserves_the_installed_version(self):
        self.install()
        (self.source / "BuildSDK/sdk.json").unlink()
        self.install(expected=1)
        self.assertTrue((self.destination / "BuildSDK/sdk.json").is_file())

    def test_unrelated_destination_is_preserved(self):
        self.destination.mkdir(parents=True)
        marker = self.destination / "user.txt"
        marker.write_text("keep")
        self.install(expected=1)
        self.assertEqual(marker.read_text(), "keep")
        self.assertFalse((self.destination / "AdaEditor.exe").exists())

    def test_overlapping_directories_are_rejected(self):
        for destination in [self.source, self.source / "nested", self.source.parent]:
            with self.subTest(destination=destination):
                self.install(destination=destination, expected=1)
                self.assertTrue((self.source / "AdaEditor.exe").is_file())

    def test_drive_root_is_rejected(self):
        self.install(destination=Path(self.root.anchor), expected=1)

    def test_release_beside_installer_uses_the_default_user_programs_directory(self):
        installer = self.source / INSTALLER.name
        shutil.copy2(INSTALLER, installer)
        environment = os.environ.copy()
        environment["LOCALAPPDATA"] = str(self.root / "Local App Data")
        self.install(source=False, destination=False, installer=installer, environment=environment)
        self.assertTrue((Path(environment["LOCALAPPDATA"]) / "Programs/Ada Studio/AdaEditor.exe").is_file())
        launcher = installer.with_suffix(".cmd")
        shutil.copy2(INSTALLER.with_suffix(".cmd"), launcher)
        environment["ADA_INSTALLER_TEST"] = str(launcher)
        # Use cmd's quoting directly; list2cmdline escapes quotes for C argv parsers.
        result = subprocess.run('cmd.exe /d /c call "%ADA_INSTALLER_TEST%" -NoShortcut',
                                input=b"", capture_output=True, timeout=45, cwd=self.root, env=environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_junction_destination_is_rejected(self):
        # Windows PowerShell's New-Item interprets wildcard characters in -Target.
        plain_source = self.root / "Actual distribution"
        self.source.rename(plain_source)
        self.source = plain_source
        self.destination.parent.mkdir()
        junction_script = self.root / "junction.ps1"
        junction_script.write_text("param([string]$Link, [string]$Target)\n"
                                   "$ErrorActionPreference = 'Stop'\n"
                                   "$null = New-Item -ItemType Junction -Path $Link -Target $Target\n")
        result = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(junction_script),
                                 str(self.destination), str(self.source)], capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.addCleanup(lambda: os.rmdir(self.destination) if self.destination.exists() else None)
        self.install(expected=1)
        self.assertTrue((self.source / "BuildSDK/sdk.json").is_file())

    def test_running_installed_application_must_be_closed_before_updating(self):
        self.install()
        environment = os.environ.copy()
        environment["PYTHONHOME"] = sys.prefix
        process = subprocess.Popen([str(self.destination / "AdaEditor.exe"), "-u", "-c",
                                    "import time; print('ready', flush=True); time.sleep(30)"],
                                   env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(process.stdout.readline().strip(), b"ready")
            self.install(expected=1)
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            process.communicate(timeout=15)


if __name__ == "__main__":
    unittest.main()
