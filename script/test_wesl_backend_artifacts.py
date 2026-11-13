"""Exercise WESL backend emission through the production host tool."""

import os
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path


class WESLBackendArtifactTests(unittest.TestCase):
    def compile(self, root, target, *arguments):
        return subprocess.run(
            [os.environ["ADAENGINE_TEST_WESL_TRANSPILER"], "--input", str(root / "main.wesl"),
             "--output-directory", str(root / "output"), "--target", target, *arguments],
            capture_output=True, text=True, check=False,
        )

    def test_msl_emits_each_selected_stage_from_one_module(self):
        with tempfile.TemporaryDirectory(prefix="ada-wesl-backend-") as temporary:
            root = Path(temporary)
            (root / "main.wesl").write_text(
                "@vertex fn vertexMain() -> @builtin(position) vec4f { return vec4f(0, 0, 0, 1); }"
                "@fragment fn fragmentMain() -> @location(0) vec4f { return vec4f(1); }", encoding="utf-8",
            )
            result = self.compile(root, "msl")
            self.assertEqual(result.returncode, 0, result.stderr)
            vertex = (root / "output/main.vert.msl").read_text(encoding="utf-8")
            fragment = (root / "output/main.frag.msl").read_text(encoding="utf-8")
            self.assertIn("vertex", vertex)
            self.assertIn("fragment", fragment)
            self.assertNotIn("gl_Position", vertex)

    def test_spirv_is_binary_and_preserves_feature_variant_identity(self):
        with tempfile.TemporaryDirectory(prefix="ada-wesl-backend-") as temporary:
            root = Path(temporary)
            (root / "main.wesl").write_text(
                "@if(bright) const value = 1.0; @else const value = 0.0;"
                "@fragment fn fragmentMain() -> @location(0) vec4f { return vec4f(value); }", encoding="utf-8",
            )
            for arguments in [(), ("--feature", "bright")]:
                result = self.compile(root, "spirv", *arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
            plain = (root / "output/main.frag.spv").read_bytes()
            bright = (root / "output/main.bright.frag.spv").read_bytes()
            self.assertEqual(struct.unpack("<I", plain[:4])[0], 0x07230203)
            self.assertEqual(len(plain) % 4, 0)
            self.assertNotEqual(plain, bright)

    def test_compute_uses_the_same_backend_path(self):
        with tempfile.TemporaryDirectory(prefix="ada-wesl-backend-") as temporary:
            root = Path(temporary)
            (root / "main.wesl").write_text(
                "@group(0) @binding(0) var<storage, read_write> result: array<u32>;"
                "@compute @workgroup_size(1) fn computeMain() { result[0] = 42u; }", encoding="utf-8",
            )
            for target, suffix in [("msl", "msl"), ("spirv", "spv")]:
                result = self.compile(root, target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((root / f"output/main.comp.{suffix}").stat().st_size > 0)

    def test_native_output_rejects_modules_without_entry_points(self):
        with tempfile.TemporaryDirectory(prefix="ada-wesl-backend-") as temporary:
            root = Path(temporary)
            (root / "main.wesl").write_text("fn helper() -> f32 { return 1.0; }", encoding="utf-8")
            for target in ["msl", "spirv"]:
                result = self.compile(root, target)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Native WESL output requires at least one entry point", result.stderr)
                self.assertFalse((root / "output").exists())

    def test_web_stage_naming_cannot_be_combined_with_native_output(self):
        with tempfile.TemporaryDirectory(prefix="ada-wesl-backend-") as temporary:
            root = Path(temporary)
            (root / "main.wesl").write_text(
                "@fragment fn fragmentMain() -> @location(0) vec4f { return vec4f(1); }", encoding="utf-8",
            )
            result = self.compile(root, "msl", "--web-stages")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("--web-stages requires WGSL output", result.stderr)
            self.assertFalse((root / "output").exists())


if __name__ == "__main__":
    unittest.main()
