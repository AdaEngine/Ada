"""Filesystem regression for the standalone SDK staging path."""

import importlib.util
import json
import os
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
            saga = root / "SAGA"
            for base, files in [(engine, ["Package.swift", "LICENSE", "Sources/Runtime.swift", "Sources/.build/private", ".git/config", "script/ensure_tint.py", "Demos/Example/binary.glb"]),
                                (saga, ["Package.swift", "Sources/SAGACompiler/Compiler.swift", "Sources/.build/private", ".git/config"]),
                                (compiler, ["Package.swift", "LICENSE", "src/shared/header.h", "tools/aot_build.py", "binding/Runtime.swift"])]:
                for name in files:
                    path = base / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(name)
            host = compiler / ("gravity.exe" if os.name == "nt" else "gravity")
            host.write_text("#!/bin/sh\nexit 0\n")
            host.chmod(0o755)
            destination = root / "Moved Studio.app/Contents/Resources/BuildSDK"
            with patch.object(sdk.subprocess, "run"):
                sdk.stage(engine, compiler, destination)
            self.assertEqual(json.loads((destination / "sdk.json").read_text())["schemaVersion"], 1)
            self.assertTrue((destination / "AdaEngine/Sources/Runtime.swift").is_file())
            self.assertTrue((destination / "AdaEngine/script/ensure_tint.py").is_file())
            self.assertTrue((destination / "AdaScript" / host.name).is_file())
            self.assertTrue((destination / "AdaScript/LICENSE").is_file())
            self.assertTrue((destination / "SAGA/Package.swift").is_file())
            self.assertTrue((destination / "SAGA/Sources/SAGACompiler/Compiler.swift").is_file())
            self.assertFalse((destination / "SAGA/Sources/.build").exists())
            self.assertFalse((destination / "AdaEngine/.git").exists())
            self.assertFalse((destination / "AdaEngine/Demos").exists())
            self.assertFalse((destination / "AdaEngine/Sources/.build").exists())
            self.assertFalse((engine / "sdk.json").exists())
            # A second stage replaces the complete SDK without accumulating nested copies.
            with patch.object(sdk.subprocess, "run"):
                sdk.stage(engine, compiler, destination)
            self.assertFalse((destination / "BuildSDK").exists())

    def test_sdk_includes_local_studio_core_package(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engine = root / "engine"
            compiler = root / "compiler"
            package = engine / "Editor/StudioCore/Package.swift"
            source = package.parent / "Sources/AdaStudioCore/Core.swift"
            source.parent.mkdir(parents=True)
            package.write_text("local package")
            source.write_text("Swift source")
            compiler.mkdir()
            for host in ("gravity", "gravity.exe"):
                executable = compiler / host
                executable.touch()
                executable.chmod(0o755)
            destination = root / "Moved Studio/BuildSDK"
            with patch.object(sdk.subprocess, "run"):
                sdk.stage(engine, compiler, destination)
            staged_package = destination / "AdaEngine/Editor/StudioCore/Package.swift"
            self.assertTrue(staged_package.is_file())
            self.assertEqual(staged_package.read_text(), "local package")
            self.assertTrue((staged_package.parent / "Sources/AdaStudioCore/Core.swift").is_file())

    def test_sdk_keeps_bundled_browser_wasi_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engine = root / "engine"
            compiler = root / "compiler"
            shim = "Plugins/AdaWebExportPlugin/BrowserWASIShim/dist"
            for relative in (shim + "/index.js", shim + "/wasi.js", "Demos/Project/dist/generated.txt"):
                file = engine / relative
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(relative)
            compiler.mkdir()
            for host in ("gravity", "gravity.exe"):
                executable = compiler / host
                executable.touch()
                executable.chmod(0o755)
            destination = root / "BuildSDK"
            with patch.object(sdk.subprocess, "run"):
                sdk.stage(engine, compiler, destination)
            staged_engine = destination / "AdaEngine"
            self.assertTrue((staged_engine / shim / "index.js").is_file())
            self.assertTrue((staged_engine / shim / "wasi.js").is_file())
            self.assertFalse((staged_engine / "Demos/Project/dist").exists())

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
            host=compiler/("gravity.exe" if os.name == "nt" else "gravity")
            host.write_text("#!/bin/sh\nexit 0\n")
            host.chmod(0o755)
            destination=root/"Studio.app/Contents/Resources/BuildSDK"
            with patch.object(sdk.subprocess, "run"):
                sdk.stage(engine,compiler,destination,swan)
            moved=root/"Relocated/BuildSDK"
            moved.parent.mkdir()
            destination.rename(moved)
            self.assertTrue(json.loads((moved/"sdk.json").read_text())["android"])
            self.assertEqual((moved/"Swan/Dawn/dist/android.artifactbundle/arm64/libwebgpu_dawn.a").read_text(),"fixture")
            self.assertTrue((moved/"AdaEngine/Tools/Android/android.py").is_file())


if __name__ == "__main__":
    unittest.main()
