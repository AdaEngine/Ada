import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

spec=importlib.util.spec_from_file_location("android",Path(__file__).parents[1]/"android.py")
android=importlib.util.module_from_spec(spec)
spec.loader.exec_module(android)

class AndroidPackagingTests(unittest.TestCase):
    def test_build_requires_explicit_external_package(self):
        for command in ("build", "run"):
            result = subprocess.run([sys.executable, str(Path(android.__file__)), command], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("--package is required", result.stderr)

    def test_apk_preserves_every_manifest_asset_and_utf8_filename(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            binary=root/"bin"
            staging=root/"staging"
            bundle=binary/"Game.resources"/"Assets"
            bundle.mkdir(parents=True)
            (bundle/".gitkeep").touch()
            (bundle/"Текстура 🌈.png").write_bytes(bytes(range(256)))
            android.stage_resources(binary,staging/"assets")
            library=staging/"lib/arm64-v8a/libGame.so"
            library.parent.mkdir(parents=True)
            library.write_bytes(b"native runtime")
            apk=root/"unsigned.apk"
            with zipfile.ZipFile(apk,"w") as archive:
                archive.writestr("AndroidManifest.xml",b"manifest")
            android.append_payload(apk,staging)
            with zipfile.ZipFile(apk) as archive:
                self.assertIsNone(archive.testzip())
                for path in archive.read("assets/bundles/manifest.txt").decode("utf-8").splitlines():
                    self.assertIn("assets/bundles/"+path,archive.namelist())
                asset=archive.getinfo("assets/bundles/Game.resources/Assets/Текстура 🌈.png")
                self.assertTrue(asset.flag_bits & 0x800)
                self.assertEqual(archive.read(asset),bytes(range(256)))
                self.assertEqual(archive.getinfo("lib/arm64-v8a/libGame.so").compress_type,zipfile.ZIP_STORED)

    def test_java_host_dex_and_utf8_resources_share_the_apk(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            staging=root/"staging"
            asset=staging/"assets/bundles/Studio.resources/Привет.txt"
            asset.parent.mkdir(parents=True)
            asset.write_bytes("🙂".encode("utf-8"))
            dex=root/"classes.dex"
            dex.write_bytes(b"dex\n035\0host")
            apk=root/"unsigned.apk"
            with zipfile.ZipFile(apk,"w") as archive:
                archive.writestr("AndroidManifest.xml",b"manifest")
            android.append_payload(apk,staging,[dex])
            with zipfile.ZipFile(apk) as archive:
                self.assertIsNone(archive.testzip())
                self.assertEqual(archive.read("classes.dex"),dex.read_bytes())
                self.assertEqual(archive.read(asset.relative_to(staging).as_posix()),asset.read_bytes())

    def test_preserves_nested_resource_manifest_and_binary_font(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            binary=root/"bin"
            assets=root/"assets"
            bundle=binary/"Game_GameNative.resources"/"Assets"
            bundle.mkdir(parents=True)
            (bundle/"manifest.txt").write_text("game manifest")
            (bundle/"font.ttf").write_bytes(bytes(range(256)))
            android.stage_resources(binary,assets)
            index=(assets/"bundles/manifest.txt").read_text().splitlines()
            self.assertEqual(index,["Game_GameNative.resources/Assets/font.ttf","Game_GameNative.resources/Assets/manifest.txt"])
            self.assertEqual((assets/"bundles/Game_GameNative.resources/Assets/font.ttf").read_bytes(),bytes(range(256)))
            self.assertEqual((assets/"bundles/Game_GameNative.resources/Assets/manifest.txt").read_text(),"game manifest")

    def test_second_abi_does_not_leave_files_deleted_from_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            binary=root/"bin"
            assets=root/"assets"
            bundle=binary/"Game_GameNative.resources"
            bundle.mkdir(parents=True)
            (bundle/"old.txt").write_text("old")
            android.stage_resources(binary,assets)
            (bundle/"old.txt").unlink()
            (bundle/"new.txt").write_text("new")
            android.stage_resources(binary,assets)
            self.assertFalse((assets/"bundles/Game_GameNative.resources/old.txt").exists())
            self.assertEqual((assets/"bundles/manifest.txt").read_text(),"Game_GameNative.resources/new.txt\n")

    def test_refuses_apk_without_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            (root/"bin").mkdir()
            with self.assertRaises(android.AndroidError):
                android.stage_resources(root/"bin",root/"assets")

    def test_native_activity_manifest_has_exported_entry_and_no_dex_requirement(self):
        with tempfile.TemporaryDirectory() as temporary:
            args=android.parser().parse_args(["build","--label",'Game & "test"'])
            path=Path(temporary)/"AndroidManifest.xml"
            android.write_manifest(path,args)
            manifest=ET.parse(path).getroot()
            app=manifest.find("application")
            self.assertEqual(app.attrib[android.ANDROID+"hasCode"],"false")
            self.assertEqual(app.attrib[android.ANDROID+"label"],'Game & "test"')
            activity=app.find("activity")
            self.assertEqual(activity.attrib[android.ANDROID+"exported"],"true")
            self.assertEqual(activity.find("meta-data").attrib[android.ANDROID+"value"],"AndroidDemo")

    def test_rejects_incompatible_api_level_before_building(self):
        args=android.parser().parse_args(["build","--min-sdk","28"])
        with self.assertRaises(android.AndroidError):
            android.validate_options(args)

    def test_studio_manifest_enables_dex_and_excludes_keystore_backup(self):
        with tempfile.TemporaryDirectory() as temporary:
            source=Path(temporary)/"StudioActivity.java"
            source.write_text("class StudioActivity {}")
            args=android.parser().parse_args([
                "build", "--product", "AdaStudioMobile", "--activity", "org.adaengine.studio.StudioActivity",
                "--java-source", str(source)
            ])
            android.validate_options(args)
            path=Path(temporary)/"AndroidManifest.xml"
            android.write_manifest(path,args)
            app=ET.parse(path).getroot().find("application")
            self.assertEqual(app.attrib[android.ANDROID+"hasCode"],"true")
            self.assertEqual(app.attrib[android.ANDROID+"allowBackup"],"false")
            self.assertEqual(app.find("activity").attrib[android.ANDROID+"name"],"org.adaengine.studio.StudioActivity")
            self.assertEqual(app.find("activity/meta-data").attrib[android.ANDROID+"value"],"AdaStudioMobile")

    def test_custom_activity_requires_source(self):
        args=android.parser().parse_args(["build", "--activity", "org.adaengine.studio.StudioActivity"])
        with self.assertRaisesRegex(android.AndroidError,"--java-source"):
            android.validate_options(args)

    def test_custom_activity_requires_qualified_class_name(self):
        args=android.parser().parse_args(["build", "--activity", "StudioActivity"])
        with self.assertRaisesRegex(android.AndroidError,"fully qualified"):
            android.validate_options(args)

    def test_browser_callback_returns_to_the_existing_activity(self):
        with tempfile.TemporaryDirectory() as temporary:
            source=Path(temporary)/"StudioActivity.java"
            source.write_text("class StudioActivity {}")
            args=android.parser().parse_args([
                "build", "--activity", "org.adaengine.studio.StudioActivity", "--java-source", str(source),
                "--callback-url", "adaeditor://cloud/callback"
            ])
            android.validate_options(args)
            path=Path(temporary)/"AndroidManifest.xml"
            android.write_manifest(path,args)
            activity=ET.parse(path).getroot().find("application/activity")
            self.assertEqual(activity.attrib[android.ANDROID+"launchMode"],"singleTask")
            link=activity.findall("intent-filter")[1]
            self.assertEqual(link.find("data").attrib,{
                android.ANDROID+"scheme":"adaeditor",android.ANDROID+"host":"cloud",android.ANDROID+"path":"/callback"
            })
            self.assertIn("android.intent.category.BROWSABLE",[item.attrib[android.ANDROID+"name"] for item in link.findall("category")])

    def test_callback_without_a_java_host_is_rejected(self):
        args=android.parser().parse_args(["build", "--callback-url", "adaeditor://cloud/callback"])
        with self.assertRaisesRegex(android.AndroidError,"Java host"):
            android.validate_options(args)

if __name__=="__main__":
    unittest.main()

class AndroidWebGPUSetupTests(unittest.TestCase):
    def test_saga_build_uses_the_checkout_without_requiring_dawn(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout=Path(temporary)/"SAGA checkout"
            checkout.mkdir()
            (checkout/"Package.swift").write_text("// fixture")
            from unittest.mock import patch
            with patch.dict("os.environ",{"ADAENGINE_SAGA_NATIVE":"1","ADAENGINE_SAGA_PACKAGE_PATH":str(checkout)},clear=True):
                env=android.build_env()
            self.assertEqual(env.get("ADAENGINE_DISABLE_SWAN"),"1","SAGA builds must disable Swan")
            self.assertEqual(env["ADAENGINE_SAGA_PACKAGE_PATH"],str(checkout.resolve()))

    def test_requires_explicit_android_dawn_setup(self):
        args=android.parser().parse_args(["build"])
        with self.assertRaisesRegex(android.AndroidError,"ADAENGINE_SWAN_PACKAGE_PATH"):
            android.validate_webgpu(args,{})

    def test_rejects_an_unbuilt_abi_before_swift_build(self):
        import json
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            (root/"Package.swift").write_text("// fixture")
            bundle=root/"android.artifactbundle"
            bundle.mkdir()
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

class AndroidSDKSelectionTests(unittest.TestCase):
    def test_export_staging_does_not_change_sdk_import_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            bundle=root/"sdk.artifactbundle/swift-android"
            bundle.mkdir(parents=True)
            first=android.parser().parse_args(["build","--scratch",str(root/"cache"),"--output",str(root/"stage-one")])
            second=android.parser().parse_args(["build","--scratch",str(root/"cache"),"--output",str(root/"stage-two")])
            self.assertEqual(android.select_swift_sdks(first,bundle),android.select_swift_sdks(second,bundle))
            self.assertEqual((android.select_swift_sdks(first,bundle)/(first.swift_sdk+".artifactbundle")).resolve(),bundle.parent.resolve())
            self.assertFalse((root/"stage-one/swift-sdks").exists())
