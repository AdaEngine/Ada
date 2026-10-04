import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec=importlib.util.spec_from_file_location("android",Path(__file__).parents[1]/"android.py")
android=importlib.util.module_from_spec(spec)
spec.loader.exec_module(android)

class AndroidPackagingTests(unittest.TestCase):
    def test_preserves_nested_resource_manifest_and_binary_font(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); binary=root/"bin"; assets=root/"assets"
            bundle=binary/"Game_GameNative.resources"/"Assets"; bundle.mkdir(parents=True)
            (bundle/"manifest.txt").write_text("game manifest")
            (bundle/"font.ttf").write_bytes(bytes(range(256)))
            android.stage_resources(binary,assets)
            index=(assets/"bundles/manifest.txt").read_text().splitlines()
            self.assertEqual(index,["Game_GameNative.resources/Assets/font.ttf","Game_GameNative.resources/Assets/manifest.txt"])
            self.assertEqual((assets/"bundles/Game_GameNative.resources/Assets/font.ttf").read_bytes(),bytes(range(256)))
            self.assertEqual((assets/"bundles/Game_GameNative.resources/Assets/manifest.txt").read_text(),"game manifest")

    def test_second_abi_does_not_leave_files_deleted_from_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); binary=root/"bin"; assets=root/"assets"
            bundle=binary/"Game_GameNative.resources"; bundle.mkdir(parents=True)
            (bundle/"old.txt").write_text("old")
            android.stage_resources(binary,assets)
            (bundle/"old.txt").unlink(); (bundle/"new.txt").write_text("new")
            android.stage_resources(binary,assets)
            self.assertFalse((assets/"bundles/Game_GameNative.resources/old.txt").exists())
            self.assertEqual((assets/"bundles/manifest.txt").read_text(),"Game_GameNative.resources/new.txt\n")

    def test_refuses_apk_without_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); (root/"bin").mkdir()
            with self.assertRaises(android.AndroidError): android.stage_resources(root/"bin",root/"assets")

    def test_native_activity_manifest_has_exported_entry_and_no_dex_requirement(self):
        with tempfile.TemporaryDirectory() as temporary:
            args=android.parser().parse_args(["build","--label",'Game & "test"'])
            path=Path(temporary)/"AndroidManifest.xml"; android.write_manifest(path,args)
            manifest=ET.parse(path).getroot(); app=manifest.find("application")
            self.assertEqual(app.attrib[android.ANDROID+"hasCode"],"false")
            self.assertEqual(app.attrib[android.ANDROID+"label"],'Game & "test"')
            activity=app.find("activity")
            self.assertEqual(activity.attrib[android.ANDROID+"exported"],"true")
            self.assertEqual(activity.find("meta-data").attrib[android.ANDROID+"value"],"AndroidDemo")

    def test_rejects_incompatible_api_level_before_building(self):
        args=android.parser().parse_args(["build","--min-sdk","28"])
        with self.assertRaises(android.AndroidError): android.validate_options(args)

if __name__=="__main__": unittest.main()

class AndroidWebGPUSetupTests(unittest.TestCase):
    def test_requires_explicit_android_dawn_setup(self):
        args=android.parser().parse_args(["build"])
        with self.assertRaisesRegex(android.AndroidError,"ADAENGINE_SWAN_PACKAGE_PATH"):
            android.validate_webgpu(args,{})

    def test_rejects_an_unbuilt_abi_before_swift_build(self):
        import json
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); (root/"Package.swift").write_text("// fixture")
            bundle=root/"android.artifactbundle"; bundle.mkdir()
            (bundle/"lib.a").write_bytes(b"library")
            (bundle/"info.json").write_text(json.dumps({"artifacts":{"dawn":{"variants":[
                {"path":"lib.a","supportedTriples":["aarch64-unknown-linux-android29"]}
            ]}}}))
            env={"ADAENGINE_SWAN_PACKAGE_PATH":str(root),"SWAN_LOCAL_DAWN":"android.artifactbundle"}
            arm64=android.parser().parse_args(["build"])
            self.assertEqual(android.validate_webgpu(arm64,env),bundle.resolve())
            x86=android.parser().parse_args(["build","--abi","x86_64"])
            with self.assertRaisesRegex(android.AndroidError,"x86_64-unknown-linux-android29"):
                android.validate_webgpu(x86,env)
