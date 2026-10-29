"""Exercise the Windows AdaMCP package staging without changing its pinned checkout."""
import importlib.util
import shutil
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ensure_mcp", Path(__file__).with_name("ensure_windows_mcp.py"))
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)


class WindowsMCPStagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        patch_file = Path(temporary.name) / "inspection.patch"
        patch_file.write_bytes(b"--- a/inspection.swift\n+++ b/inspection.swift\n@@ -1 +1 @@\n-before\n+after\n")
        override = patch.object(mcp, "INSPECTION_PATCH", patch_file)
        override.start()
        self.addCleanup(override.stop)

    def make_source(self, root):
        source = root / "pinned"
        source.mkdir()
        (source / "inspection.swift").write_bytes(b"before\n")
        (source / "Package.swift").write_text("// pinned package", encoding="utf-8")
        (source / ".git").mkdir()
        (source / "Packages").mkdir()
        (source / "Packages" / "AdaEngine").write_text("developer-local link", encoding="utf-8")
        grouped = {}
        for relative, original, replacement in mcp.PATCHES:
            grouped.setdefault(relative, []).append(original)
        for relative, originals in grouped.items():
            target = source / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("\n".join(originals) + "\n", encoding="utf-8")
        return source

    def test_staging_patches_capture_and_discovery_and_preserves_originals(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.make_source(root)
            destination = root / "windows"
            snapshots = {relative: (source / relative).read_text() for relative, _, _ in mcp.PATCHES}
            mcp.prepare_windows_package(source, destination)
            mcp.prepare_windows_package(source, destination)
            self.assertEqual((source / "inspection.swift").read_text(), "before\n")
            self.assertEqual((destination / "inspection.swift").read_text(), "after\n")
            self.assertFalse((destination / ".git").exists())
            self.assertFalse((destination / "Packages").exists())
            self.assertTrue((destination / "Package.swift").is_file())
            for relative in {patch[0] for patch in mcp.PATCHES}:
                original_text = snapshots[relative]
                expected = original_text
                for path, original, replacement in mcp.PATCHES:
                    if path == relative:
                        expected = expected.replace(original, replacement)
                self.assertEqual((source / relative).read_text(), original_text)
                self.assertEqual((destination / relative).read_text(), expected)

    def test_readback_only_package_is_upgraded_to_exclusive_access(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.make_source(root)
            destination = root / "windows"
            shutil.copytree(source, destination)
            for relative in mcp.CAPTURE_FILES:
                target = destination / relative
                target.write_text(target.read_text().replace(mcp.ORIGINAL, mcp.REPLACEMENT), encoding="utf-8")
            mcp.prepare_windows_package(source, destination)
            for relative in mcp.CAPTURE_FILES:
                self.assertIn("withExclusiveWorldAccess", (destination / relative).read_text())

    def test_unexpected_staged_changes_are_preserved_and_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.make_source(root)
            destination = root / "windows"
            mcp.prepare_windows_package(source, destination)
            target = destination / mcp.DISCOVERY_FILE
            changed = target.read_text().replace("Data.write atomically", "Data.write changed")
            target.write_text(changed, encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "Unexpected AdaMCP staged modifications"):
                mcp.prepare_windows_package(source, destination)
            self.assertEqual(target.read_text(), changed)

    def test_incompatible_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.make_source(root)
            (source / mcp.CAPTURE_FILES[0]).write_text("unexpected capture API", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "Unexpected AdaMCP compatibility source"):
                mcp.prepare_windows_package(source, root / "windows")

    def test_inspection_edits_are_preserved_and_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.make_source(root)
            destination = root / "windows"
            mcp.prepare_windows_package(source, destination)
            target = destination / "inspection.swift"
            target.write_bytes(b"user change\n")
            with self.assertRaises(subprocess.CalledProcessError):
                mcp.prepare_windows_package(source, destination)
            self.assertEqual(target.read_text(), "user change\n")


if __name__ == "__main__":
    unittest.main()
