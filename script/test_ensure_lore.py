"""Exercise SDK staging with real archive I/O, hashes and ELF architecture checks."""
import hashlib
import io
import os
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

import ensure_lore


class LoreSDKTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def archive(self, target, machine=62, linked_header=False):
        binary = bytearray(64)
        binary[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", binary, 18, machine)
        files = {"lore.h": b"// API", "liblore.so": bytes(binary), "lore.dll": b"MZ", "lore.dll.lib": b"import library",
                 "LICENSE.txt": b"MIT", "THIRD-PARTY-NOTICES.txt": b"Notices"}
        archive = self.root / ("sdk.zip" if target == "windows_x86_64" else "sdk.tar.gz")
        if target == "windows_x86_64":
            with zipfile.ZipFile(archive, "w") as sdk:
                for name in ensure_lore.files_for(target):
                    sdk.writestr(name, files[name])
        else:
            with tarfile.open(archive, "w:gz") as sdk:
                for name in ensure_lore.files_for(target):
                    entry = tarfile.TarInfo("./" + name)
                    if name == "lore.h" and linked_header:
                        entry.type = tarfile.SYMTYPE
                        entry.linkname = "../private.h"
                        sdk.addfile(entry)
                    else:
                        entry.size = len(files[name])
                        sdk.addfile(entry, io.BytesIO(files[name]))
        return archive

    def stage(self, archive, target, digest=None):
        pin = {"url": archive.as_uri(), "sha256": digest or hashlib.sha256(archive.read_bytes()).hexdigest()}
        variable = "LORE_WINDOWS_SDK_PATH" if target == "windows_x86_64" else "LORE_LINUX_SDK_PATH"
        with mock.patch.dict(ensure_lore.PIN, {target: pin}), mock.patch.dict(os.environ, {variable: str(self.root / "staged")}):
            return ensure_lore.ensure_sdk(target)

    def test_linux_architectures_stage_notices_and_repair_modified_library(self):
        for target, machine in (("linux_x86_64", 62), ("linux_aarch64", 183)):
            with self.subTest(target=target):
                archive = self.archive(target, machine)
                staged = self.stage(archive, target)
                original = (staged / "liblore.so").read_bytes()
                self.assertEqual((staged / "LICENSE.txt").read_bytes(), b"MIT")
                self.assertEqual((staged / "THIRD-PARTY-NOTICES.txt").read_bytes(), b"Notices")
                (staged / "liblore.so").write_bytes(b"modified")
                self.stage(archive, target)
                self.assertEqual((staged / "liblore.so").read_bytes(), original)

    def test_windows_sdk_still_stages_the_import_library_and_dll(self):
        staged = self.stage(self.archive("windows_x86_64"), "windows_x86_64")
        self.assertEqual((staged / "lore.dll.lib").read_bytes(), b"import library")
        self.assertEqual((staged / "lore.dll").read_bytes(), b"MZ")

    def test_hash_mismatch_never_stages_library_files(self):
        with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
            self.stage(self.archive("linux_x86_64"), "linux_x86_64", "0" * 64)
        self.assertFalse((self.root / "staged/liblore.so").exists())

    def test_wrong_elf_architecture_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "does not match"):
            self.stage(self.archive("linux_aarch64", machine=62), "linux_aarch64")

    def test_archive_links_are_rejected_without_touching_their_targets(self):
        private = self.root / "private.h"
        private.write_bytes(b"keep")
        with self.assertRaisesRegex(RuntimeError, "regular file"):
            self.stage(self.archive("linux_x86_64", linked_header=True), "linux_x86_64")
        self.assertEqual(private.read_bytes(), b"keep")

    def test_architecture_aliases_and_unsupported_hosts(self):
        self.assertEqual(ensure_lore.linux_target("AMD64"), "linux_x86_64")
        self.assertEqual(ensure_lore.linux_target("arm64"), "linux_aarch64")
        with self.assertRaises(RuntimeError):
            ensure_lore.linux_target("armv7l")


if __name__ == "__main__":
    unittest.main()
