"""Exercise app-bundle installation on macOS without touching /Applications."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

INSTALLER = Path(__file__).with_name("install_studio_macos.sh").resolve()


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS ditto and PlistBuddy")
class MacOSInstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ada-install-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "Release Кириллица & spaces" / "Ada Studio.app"
        self.applications = self.root / "Applications"
        self.destination = self.applications / "Ada Studio.app"
        (self.source / "Contents/MacOS").mkdir(parents=True)
        shutil.copy2("/bin/echo", self.source / "Contents/MacOS/Ada Studio")
        (self.source / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.adaengine.editor", "CFBundleExecutable": "Ada Studio",
            "CFBundlePackageType": "APPL",
        }))
        (self.source / "Contents/.resource").write_text("resource")

    def install(self, *, source=None, destination=None, expected=0):
        result = subprocess.run(["bash", str(INSTALLER), "--source", str(source or self.source),
                                 "--destination", str(destination or self.applications)],
                                capture_output=True, timeout=30)
        if expected == 0:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_complete_copy_and_upgrade(self):
        self.install()
        self.assertEqual((self.destination / "Contents/.resource").read_text(), "resource")
        executable = self.destination / "Contents/MacOS/Ada Studio"
        result = subprocess.run([str(executable), "installed"], capture_output=True, timeout=10)
        self.assertEqual(result.stdout.strip(), b"installed")
        (self.destination / "obsolete.txt").write_text("old")
        (self.source / "Contents/.resource").write_text("updated")
        self.install()
        self.assertFalse((self.destination / "obsolete.txt").exists())
        self.assertEqual((self.destination / "Contents/.resource").read_text(), "updated")
        self.assertEqual(list(self.applications.glob(".ada-studio-install.*")), [])

    def test_invalid_source_preserves_existing_app(self):
        self.install()
        (self.source / "Contents/Info.plist").unlink()
        self.install(expected=1)
        self.assertTrue((self.destination / "Contents/Info.plist").is_file())

    def test_unrelated_destination_is_preserved(self):
        self.destination.mkdir(parents=True)
        marker = self.destination / "user.txt"
        marker.write_text("keep")
        self.install(expected=1)
        self.assertEqual(marker.read_text(), "keep")

    def test_overlapping_source_and_destination_are_rejected(self):
        for applications in [self.source.parent, self.source / "nested"]:
            with self.subTest(applications=applications):
                self.install(destination=applications, expected=1)
                self.assertTrue((self.source / "Contents/Info.plist").is_file())

    def test_symbolic_link_destination_is_rejected(self):
        self.applications.mkdir()
        self.destination.symlink_to(self.source, target_is_directory=True)
        self.install(expected=1)
        self.assertTrue(self.destination.is_symlink())


if __name__ == "__main__":
    unittest.main()
