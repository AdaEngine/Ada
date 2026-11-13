"""Run the host transpiler on real WESL files without an external linker."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class WESLTranspilerTests(unittest.TestCase):
    def compile(self, root, *arguments):
        tool = os.environ["ADAENGINE_TEST_WESL_TRANSPILER"]
        return subprocess.run(
            [tool, "--input", str(root / "main.wesl"), "--output-directory", str(root), *arguments],
            env={**os.environ, "ADAENGINE_WESL_NODE_PATH": str(root / "missing-node")},
            capture_output=True, text=True, check=False,
        )

    def test_links_import_and_builds_both_variants_inside_the_engine(self):
        with tempfile.TemporaryDirectory(prefix="ada wesl ") as temporary:
            root = Path(temporary)
            (root / "common.wesl").write_text("fn shade() -> vec4f { return vec4f(1); }", encoding="utf-8")
            main = root / "main.wesl"
            main.write_text(
                """
                import package::common::shade as baseColor;
                @if(textured) @group(0) @binding(0) var image: texture_2d<f32>;
                @fragment fn fragmentMain() -> @location(0) vec4f {
                    @if(textured)
                    return textureLoad(image, vec2i(0), 0) * baseColor();
                    @else
                    return baseColor();
                }
                """,
                encoding="utf-8",
            )
            for enabled in (False, True):
                arguments = ["--feature", "textured"] if enabled else []
                result = self.compile(root, *arguments)
                self.assertEqual(result.returncode, 0, f"In-process WESL linking failed: {result.stderr}")
                output = (root / ("main.textured.wgsl" if enabled else "main.wgsl")).read_text(encoding="utf-8")
                self.assertIn("fragmentMain", output)
                self.assertEqual("texture_2d" in output, enabled)

    def test_links_named_dependency_with_package_relative_imports(self):
        with tempfile.TemporaryDirectory(prefix="ada wesl ") as temporary:
            root = Path(temporary)
            shared = root / "shared"
            shared.mkdir()
            (shared / "color.wgsl").write_text("const tint = vec4f(1);", encoding="utf-8")
            (shared / "surface.wesl").write_text(
                "import package::color::tint; fn shade() -> vec4f { return tint; }", encoding="utf-8"
            )
            (root / "main.wesl").write_text(
                "import engine::surface::shade; @fragment fn fragmentMain() -> @location(0) vec4f { return shade(); }",
                encoding="utf-8",
            )
            result = self.compile(root, "--wesl-dependency", f"engine={shared}")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("ada_wesl_6_engine_5_color_tint", (root / "main.wgsl").read_text(encoding="utf-8"))

    def test_web_stages_keep_named_variant_sidecars_separate(self):
        with tempfile.TemporaryDirectory(prefix="ada wesl ") as temporary:
            root = Path(temporary)
            (root / "main.wesl").write_text(
                "@if(morph) const morphOffset = 1.0; @else const morphOffset = 0.0;"
                "@vertex fn vertexMain() -> @builtin(position) vec4f { return vec4f(morphOffset); }",
                encoding="utf-8",
            )
            for arguments in [("--web-stages",), ("--web-stages", "--feature", "morph")]:
                result = self.compile(root, *arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
            plain = (root / "main.wesl.vert.wgsl").read_text(encoding="utf-8")
            variant = (root / "main.wesl.morph.vert.wgsl").read_text(encoding="utf-8")
            self.assertIn("morphOffset = 0.0", plain)
            self.assertIn("morphOffset = 1.0", variant)

    def test_inactive_template_arguments_and_imports_are_removed_as_units(self):
        with tempfile.TemporaryDirectory(prefix="ada wesl ") as temporary:
            root = Path(temporary)
            (root / "main.wesl").write_text(
                """
                @if(disabled) import package::absent::helper;
                @if(disabled) alias Unused = array<u32, 4>;
                @if(disabled) @group(0) @binding(0) var<storage, read> data: array<u32>;
                struct Payload { @if(disabled) values: array<u32, 4>, color: vec4f, }
                @fragment fn fragmentMain() -> @location(0) vec4f { return Payload(vec4f(1)).color; }
                """,
                encoding="utf-8",
            )
            result = self.compile(root)
            self.assertEqual(result.returncode, 0, f"Conditional template was not removed: {result.stderr}")
            output = (root / "main.wgsl").read_text(encoding="utf-8")
            self.assertNotIn("storage", output)
            self.assertNotIn("values", output)

    def test_direct_qualified_reference_does_not_capture_root_globals(self):
        with tempfile.TemporaryDirectory(prefix="ada wesl ") as temporary:
            root = Path(temporary)
            helper = root / "common.wesl"
            helper.write_text("fn shade() -> vec4f { return vec4f(1); }", encoding="utf-8")
            (root / "main.wesl").write_text(
                """
                const hidden = vec4f(1);
                @fragment fn fragmentMain() -> @location(0) vec4f {
                    return package::common::shade();
                }
                """,
                encoding="utf-8",
            )
            self.assertEqual(self.compile(root).returncode, 0)
            helper.write_text("fn shade() -> vec4f { return hidden; }", encoding="utf-8")
            result = self.compile(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not imported", result.stderr)


if __name__ == "__main__":
    unittest.main()
