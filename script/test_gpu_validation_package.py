"""Check the generated package for the Windows AdaUI GPU regression."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class GPUValidationPackageTests(unittest.TestCase):
    def test_stages_the_geometry_regression_and_its_windows_module(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary) / "validation"
            subprocess.run(
                [sys.executable, str(root / "script/gpu_validation_package.py"), str(package)],
                check=True,
                capture_output=True,
                cwd=root,
            )
            source = root / "Tests/AdaUITests/UIShapeGeometryTests.swift"
            staged = package / "Tests/RenderingValidationTests" / source.name
            self.assertEqual(staged.read_bytes(), source.read_bytes())
            manifest = (package / "Package.swift").read_text(encoding="utf-8")
            self.assertIn('.product(name: "AdaUI", package: "AdaEngine", condition: .when(platforms: [.windows]))', manifest)


if __name__ == "__main__":
    unittest.main()
