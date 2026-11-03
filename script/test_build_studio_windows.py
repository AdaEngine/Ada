"""Exercise build logging in Windows PowerShell using real SwiftPM compilations."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

BUILDER = Path(__file__).with_name("build_studio_windows.ps1").resolve()


@unittest.skipUnless(os.name == "nt" and shutil.which("swift"), "Requires Windows and Swift")
class WindowsBuildLoggingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ada-build-logging-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.scripts = self.root / "script"
        self.scripts.mkdir()
        shutil.copy2(BUILDER, self.scripts / BUILDER.name)
        # The installer captures the builder's stdout in a pipeline. In Windows
        # PowerShell 5.1 this changes how redirected native stderr is handled.
        self.launcher = self.root / "Invoke-Builder.ps1"
        self.launcher.write_text(
            "$ErrorActionPreference = 'Stop'\n"
            "$bin = (& (Join-Path $PSScriptRoot 'script/build_studio_windows.ps1') "
            "-Jobs 1 | Select-Object -Last 1).Trim()\nWrite-Output $bin\n", encoding="utf-8")
        (self.root / ".build-tools").mkdir()
        self.editor = self.root / "Editor"
        source_directory = self.editor / "Sources/AdaEditor"
        source_directory.mkdir(parents=True)
        self.source = source_directory / "main.swift"
        (self.editor / "Package.swift").write_text(
            '// swift-tools-version: 6.0\nimport Foundation\nimport PackageDescription\n'
            'FileHandle.standardError.write(Data("studio-build-resolver-stderr\\n".utf8))\n'
            'let package = Package(name: "BuildFixture", '
            'products: [.executable(name: "AdaEditor", targets: ["AdaEditor"])], '
            'targets: [.executableTarget(name: "AdaEditor")])\n', encoding="utf-8")
        self.sdk = self.root / "SDK fixture"
        self.sdk.mkdir()
        (self.sdk / "lore.dll").write_bytes(b"fixture")
        # Dependency setup is unrelated to logging. The production build script still
        # invokes the real SwiftPM/compiler on a real package, including its stderr.
        for name in ["ensure_windows_lore.py", "ensure_windows_icon.py",
                     "ensure_windows_export_tools.py", "ensure_tint.py"]:
            (self.scripts / name).write_text(
                'import os\nprint(os.environ["ADA_STUDIO_LOGGING_TEST_SDK"])\n', encoding="utf-8")
        self.environment = os.environ.copy()
        self.environment["ADA_STUDIO_LOGGING_TEST_SDK"] = str(self.sdk)
        for name in ["ADAEDITOR_LORE_PACKAGE_PATH", "ADAEDITOR_SWIFTTERM_PACKAGE_PATH",
                     "ADA_MCP_LOCAL_PATH", "ADAENGINE_GRAVITY_PACKAGE_PATH"]:
            self.environment[name] = str(self.sdk)
        self.log = self.root / ".build-tools/studio-release-build.log"

    def build(self):
        return subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                               str(self.launcher)],
                              env=self.environment, cwd=self.root, capture_output=True, timeout=120)

    def read_log(self):
        data = self.log.read_bytes()
        return data.decode("utf-16" if data.startswith(b"\xff\xfe") else "utf-8-sig")

    def test_successful_native_stderr_does_not_abort_the_build(self):
        self.source.write_text('#warning("studio-build-stderr-warning")\nprint("built")\n', encoding="utf-8")
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        log = self.read_log()
        self.assertIn("studio-build-stderr-warning", log)
        self.assertIn("studio-build-resolver-stderr", log)
        self.assertIn("complete!", log)
        self.assertNotIn("NativeCommandError", log)
        binary_directory = Path(result.stdout.decode("utf-8-sig").strip().splitlines()[-1])
        self.assertTrue((binary_directory / "AdaEditor.exe").is_file())
        executable = subprocess.run([str(binary_directory / "AdaEditor.exe")], capture_output=True,
                                    env=self.environment, timeout=15)
        self.assertEqual(executable.returncode, 0, executable.stderr)
        self.assertEqual(executable.stdout.strip(), b"built")

    def test_native_compiler_failure_is_reported_with_the_full_log(self):
        self.source.write_text('#error("studio-build-real-failure")\n', encoding="utf-8")
        result = self.build()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("studio-build-real-failure", self.read_log())
        self.assertIn(b"Studio build failed. See", result.stderr)
        self.assertNotIn(b"NativeCommandError", result.stderr)


if __name__ == "__main__":
    unittest.main()
