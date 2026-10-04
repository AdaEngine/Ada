"""Filesystem regression for the standalone SDK staging path."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("stage_build_sdk", Path(__file__).with_name("stage-build-sdk.py"))
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)


class StageSDKTests(unittest.TestCase):
    def test_source_sdk_is_self_contained_and_omits_private_build_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engine = root / "engine"
            compiler = root / "compiler"
            for base, files in [(engine, ["Package.swift", "LICENSE", "Sources/Runtime.swift", "Sources/.build/private", ".git/config"]),
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
            self.assertTrue((destination / "AdaScript/gravity").is_file())
            self.assertTrue((destination / "AdaScript/LICENSE").is_file())
            self.assertFalse((destination / "AdaEngine/.git").exists())
            self.assertFalse((destination / "AdaEngine/Sources/.build").exists())
            self.assertFalse((engine / "sdk.json").exists())
            # A second stage replaces the complete SDK without accumulating nested copies.
            sdk.stage(engine, compiler, destination)
            self.assertFalse((destination / "BuildSDK").exists())


if __name__ == "__main__":
    unittest.main()
