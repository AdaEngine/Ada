"""Filesystem regression for the standalone SDK staging path."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("stage_build_sdk", Path(__file__).with_name("stage-build-sdk.py"))
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)


class StageSDKTests(unittest.TestCase):
    def test_compiler_discovery_prefers_checked_in_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            compiler = root / "Sources/gravity-lang"
            marker = compiler / "tools/aot_build.py"
            marker.parent.mkdir(parents=True)
            marker.touch()
            self.assertEqual(sdk.compiler_root(root, None), compiler.resolve())

    def test_compiler_discovery_supports_xcode_build_and_archive_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engine = root / "engine"
            engine.mkdir()
            derived_data = root / "DerivedData"
            compiler = derived_data / "SourcePackages/checkouts/gravity-lang"
            marker = compiler / "tools/aot_build.py"
            marker.parent.mkdir(parents=True)
            marker.touch()
            for layout in ["Build/Products", "Build/Intermediates.noindex/ArchiveIntermediates/AdaEditor-Standalone/BuildProductsPath"]:
                with self.subTest(layout=layout):
                    build_directory = derived_data / layout
                    build_directory.mkdir(parents=True)
                    with patch.dict("os.environ", {"BUILD_DIR": str(build_directory)}, clear=True):
                        self.assertEqual(sdk.compiler_root(engine, None), compiler.resolve())

    def test_source_sdk_is_self_contained_and_omits_private_build_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engine = root / "engine"
            compiler = root / "compiler"
            for base, files in [(engine, ["Package.swift", "LICENSE", "Sources/Runtime.swift", "Sources/.build/private", ".git/config", "script/ensure_tint.py", "Demos/Example/binary.glb"]),
                                (compiler, ["Package.swift", "LICENSE", "src/shared/header.h", "tools/aot_build.py", "binding/Runtime.swift"])]:
                for name in files:
                    path = base / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(name)
            host = compiler / "gravity"
            host.write_text("#!/bin/sh\nexit 0\n")
            host.chmod(0o755)
            destination = root / "Moved Studio.app/Contents/Resources/BuildSDK"
            sdk.stage(engine, compiler, destination)
            self.assertEqual(json.loads((destination / "sdk.json").read_text())["schemaVersion"], 1)
            self.assertTrue((destination / "AdaEngine/Sources/Runtime.swift").is_file())
            self.assertTrue((destination / "AdaEngine/script/ensure_tint.py").is_file())
            self.assertTrue((destination / "AdaScript/gravity").is_file())
            self.assertTrue((destination / "AdaScript/LICENSE").is_file())
            self.assertFalse((destination / "AdaEngine/.git").exists())
            self.assertFalse((destination / "AdaEngine/Demos").exists())
            self.assertFalse((destination / "AdaEngine/Sources/.build").exists())
            self.assertFalse((engine / "sdk.json").exists())
            # A second stage replaces the complete SDK without accumulating nested copies.
            sdk.stage(engine, compiler, destination)
            self.assertFalse((destination / "BuildSDK").exists())

    def test_android_sdk_keeps_dawn_static_library_after_relocation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            engine=root/"engine"
            compiler=root/"compiler"
            swan=root/"swan"
            for base, names in [(engine,["Package.swift","Tools/Android/android.py"]),(compiler,["Package.swift","tools/aot_build.py"]),
                                (swan,["Package.swift","Sources/WebGPU/WebGPU.swift","Dawn/dist/android.artifactbundle/info.json","Dawn/dist/android.artifactbundle/arm64/libwebgpu_dawn.a"])]:
                for name in names:
                    path=base/name
                    path.parent.mkdir(parents=True,exist_ok=True)
                    path.write_text("fixture")
            host=compiler/"gravity"
            host.write_text("#!/bin/sh\nexit 0\n")
            host.chmod(0o755)
            destination=root/"Studio.app/Contents/Resources/BuildSDK"
            sdk.stage(engine,compiler,destination,swan)
            moved=root/"Relocated/BuildSDK"
            moved.parent.mkdir()
            destination.rename(moved)
            self.assertTrue(json.loads((moved/"sdk.json").read_text())["android"])
            self.assertEqual((moved/"Swan/Dawn/dist/android.artifactbundle/arm64/libwebgpu_dawn.a").read_text(),"fixture")
            self.assertTrue((moved/"AdaEngine/Tools/Android/android.py").is_file())


if __name__ == "__main__":
    unittest.main()
