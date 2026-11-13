"""Exercise the CLI, filesystem transactions, archives and real SwiftPM logging."""
import argparse
import contextlib
from functools import partial
import hashlib
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.request import Request
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from script.ada_tools.cli import parser
from script.ada_tools.context import Context, DownloadRedirects, PIN, ToolError, download, extract_tar, extract_zip
from script.ada_tools import environment, studio, web
from script.ada_tools.web import PreviewHandler
ROOT = Path(__file__).resolve().parents[1]


def fixture(directory, host="windows"):
    directory.mkdir(parents=True)
    files = ["AdaEditor.exe", "adastudio.exe"] if host == "windows" else ["AdaEditor", "ada-studio", "adastudio", "lib/liblore.so"]
    for name in files:
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(sys.executable, path)
        path.chmod(0o755)
    for name, value in {"BuildSDK/sdk.json": '{"schemaVersion": 1}', "AdaEditor_AdaEditor.resources/Assets/a.txt": "asset",
                        "AdaEngine_AdaRender.resources/shader.txt": "shader", ".hidden": "hidden"}.items():
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")


class CLIParsingTests(unittest.TestCase):
    def test_default_prepare_selects_all_profiles(self):
        self.assertEqual(parser().parse_args(["prepare"]).components, [])

    def test_common_flags_work_on_both_sides_of_subcommands(self):
        for arguments in [["--dry-run", "--jobs", "3", "install", "studio", "--debug"],
                          ["install", "--dry-run", "studio", "--jobs", "3", "--debug"],
                          ["install", "studio", "--dry-run", "--jobs", "3", "--debug"]]:
            with self.subTest(arguments=arguments):
                args = parser().parse_args(arguments)
                self.assertTrue(args.dry_run)
                self.assertTrue(args.debug)
                self.assertEqual(args.jobs, 3)

    def test_bad_component_and_job_count_are_usage_errors(self):
        for arguments in [["prepare", "unknown"], ["build", "studio", "--jobs", "0"]]:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                parser().parse_args(arguments)
            self.assertEqual(raised.exception.code, 2)

    def test_entry_point_works_from_another_working_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(ROOT / "ada_tool.py"), "install", "studio", "--help"],
                                    cwd=directory, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--source", result.stdout)
        self.assertIn("--debug", result.stdout)

    def test_prepare_dry_run_never_writes_for_any_host(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "Editor/WebUI/package.json"
            package.parent.mkdir(parents=True)
            package.write_text('{"packageManager":"pnpm@11.25.0"}')
            before = set(root.rglob("*"))
            for host in ("windows", "macos", "linux"):
                with self.subTest(host=host), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    args = parser().parse_args(["prepare", "--dry-run"])
                    ctx = Context(args, root=root, host=host)
                    environment.prepare(ctx, args)
                    self.assertEqual(set(root.rglob("*")), before)

    def test_missing_swift_is_reported_without_traceback(self):
        result = subprocess.run([sys.executable, str(ROOT / "ada_tool.py"), "build", "engine", "--swift", "missing-ada-swift"],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 1)
        self.assertIn("prepare swift", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_managed_configuration_does_not_override_explicit_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            args = parser().parse_args(["doctor"])
            ctx = Context(args, root=directory)
            ctx.set("TINT_EXECUTABLE", "saved-tint")
            ctx.save()
            with patch.dict(os.environ, {"TINT_EXECUTABLE": "explicit-tint"}):
                restored = Context(args, root=directory)
            self.assertEqual(restored.env["TINT_EXECUTABLE"], "explicit-tint")
            saved = json.loads((ctx.cache / "environment.json").read_text())
            self.assertNotIn("PATH", saved["environment"])
            self.assertNotIn("environment", saved["environment"])

    def test_repeated_tool_environment_setup_keeps_path_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            ctx = Context(argparse.Namespace(), root=directory, host="windows")
            ctx.env["PATH"] = ""
            binary = str(Path(directory) / "Build Tools/bin")
            for _ in range(100):
                ctx.prepend(binary)
                ctx.prepend(binary.upper().replace("/", "\\") + "\\")
            self.assertEqual(len(ctx.env["PATH"].split(os.pathsep)), 1)
            self.assertEqual(len(ctx.bins), 1)

    def test_installed_launch_uses_bundled_sdk_and_keeps_explicit_overrides(self):
        with tempfile.TemporaryDirectory() as directory:
            ctx = Context(argparse.Namespace(), root=directory)
            ctx.set("ADAENGINE_PACKAGE_PATH", directory)
            ctx.set("TINT_EXECUTABLE", "cached-tint")
            with patch.dict(os.environ, {"TINT_EXECUTABLE": "explicit-tint"}):
                ctx.env["TINT_EXECUTABLE"] = os.environ["TINT_EXECUTABLE"]
                launch = studio.launch_environment(ctx)
            self.assertEqual(launch["TINT_EXECUTABLE"], "explicit-tint")
            if "ADAENGINE_PACKAGE_PATH" not in os.environ:
                self.assertNotIn("ADAENGINE_PACKAGE_PATH", launch)
            self.assertEqual(ctx.env["ADAENGINE_PACKAGE_PATH"], directory)

    def test_doctor_reports_missing_requirements_as_json_without_saving_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "Editor/WebUI/package.json"
            package.parent.mkdir(parents=True)
            package.write_text('{"packageManager":"pnpm@11.25.0"}')
            args = parser().parse_args(["doctor", "--profile", "playground", "--json"])
            ctx = Context(args, root=root)
            output = io.StringIO()
            before = set(root.rglob("*"))
            with contextlib.redirect_stdout(output):
                status = environment.doctor(ctx, args)
            report = json.loads(output.getvalue())
            self.assertEqual(status, 1)
            self.assertFalse(report["ok"])
            self.assertTrue(any(c["name"] == "Cloud panels" and not c["ok"] for c in report["checks"]))
            self.assertEqual(set(root.rglob("*")), before)

    def test_studio_build_plans_select_native_products_and_debug_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for host in ("windows", "macos", "linux"):
                args = parser().parse_args(["build", "studio", "--debug", "--dry-run"])
                ctx = Context(args, root=root, host=host)
                if host == "windows":
                    ctx.arch = "x86_64"
                output = io.StringIO()
                with contextlib.redirect_stderr(output):
                    studio.build(ctx, args)
                plan = output.getvalue()
                if host == "windows":
                    self.assertIn("--product AdaEditor", plan)
                    self.assertNotIn("AdaEditorPackageTests", plan)
                elif host == "macos":
                    self.assertIn("-scheme AdaEditor-Standalone", plan)
                    self.assertIn("-configuration Debug", plan)
                else:
                    self.assertIn("--configuration debug", plan)
                self.assertEqual(list(root.iterdir()), [])

    def test_profile_build_keeps_release_optimizations_and_emits_symbols(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for host in ("windows", "macos", "linux"):
                for target in ("studio", "engine"):
                    args = parser().parse_args(["build", target, "--profile", "--dry-run"])
                    ctx = Context(args, root=root, host=host)
                    ctx.arch = "x86_64"
                    output = io.StringIO()
                    with contextlib.redirect_stderr(output):
                        studio.build(ctx, args)
                    plan = output.getvalue()
                    if host == "macos" and target == "studio":
                        self.assertIn("-configuration Release", plan)
                        self.assertIn("DEBUG_INFORMATION_FORMAT=dwarf-with-dsym", plan)
                    else:
                        self.assertIn("--configuration release", plan)
                        self.assertIn("-Xswiftc -g", plan)
                    if host == "windows" and target == "studio":
                        self.assertIn("-Xswiftc -debug-info-format=codeview", plan)
                        self.assertIn("-Xlinker -debug", plan)
                    # Profiling builds never reuse or invalidate the plain release cache.
                    self.assertIn(target + "-profile", plan)
                    self.assertEqual(list(root.iterdir()), [])
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            parser().parse_args(["build", "studio", "--profile", "--debug"])
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            parser().parse_args(["run", "studio", "--profile", "--debug"])

    def test_profile_installation_lives_beside_release_and_debug(self):
        with tempfile.TemporaryDirectory() as directory:
            for host in ("windows", "macos", "linux"):
                ctx = Context(parser().parse_args(["run", "studio", "--dry-run"]), root=Path(directory), host=host)
                names = [studio.default_destination(ctx, debug, profile).name
                         for debug, profile in ((False, False), (True, False), (False, True))]
                self.assertEqual(len(set(names)), 3, names)
                self.assertTrue("Profile" in names[2] or names[2] == "ada-studio-profile", names)
            args = parser().parse_args(["install", "studio", "--profile", "--dry-run", "--no-shortcut"])
            self.assertTrue(args.profile)
            self.assertFalse(args.debug)

    def test_windows_wasm_plan_uses_worker_compiler_and_reuses_frontend(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = parser().parse_args(["build", "wasm", "--dry-run", "--ui-dist", str(root / "ui")])
            args.studio_origin = ["http://127.0.0.1:8080"]
            ctx = Context(args, root=root, host="windows")
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                web.wasm(ctx, args)
            self.assertIn("wsl.exe", output.getvalue())
            self.assertIn("BuildTools/swift-6.3.2/usr/bin/swift", output.getvalue())
            self.assertIn("--ui-dist", output.getvalue())
            self.assertEqual(list(root.iterdir()), [])


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ada-tool-install-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "Source [v1] Кириллица & spaces"
        self.destination = self.root / "Programs/Ada Studio"
        fixture(self.source)

    def test_relocation_and_upgrade_remove_obsolete_files(self):
        studio.atomic_install(self.source, self.destination, "windows")
        self.assertEqual((self.destination / ".hidden").read_text(), "hidden")
        (self.destination / "obsolete.dll").write_text("old")
        (self.source / "AdaEngine_AdaRender.resources/shader.txt").write_text("new")
        studio.atomic_install(self.source, self.destination, "windows")
        self.assertFalse((self.destination / "obsolete.dll").exists())
        self.assertEqual((self.destination / "AdaEngine_AdaRender.resources/shader.txt").read_text(), "new")
        self.assertEqual(list(self.destination.parent.glob(".ada-studio-*")), [])

    def test_incomplete_source_and_unrelated_destination_are_preserved(self):
        studio.atomic_install(self.source, self.destination, "windows")
        (self.source / "BuildSDK/sdk.json").unlink()
        with self.assertRaises(ToolError):
            studio.atomic_install(self.source, self.destination, "windows")
        self.assertTrue((self.destination / "BuildSDK/sdk.json").is_file())
        unrelated = self.root / "unrelated"
        unrelated.mkdir()
        (unrelated / "keep.txt").write_text("keep")
        with self.assertRaises(ToolError):
            studio.atomic_install(self.destination, unrelated, "windows")
        self.assertEqual((unrelated / "keep.txt").read_text(), "keep")

    def test_overlapping_paths_are_rejected(self):
        for destination in (self.source, self.source / "nested", self.source.parent, Path(self.root.anchor)):
            with self.subTest(destination=destination), self.assertRaises(ToolError):
                studio.atomic_install(self.source, destination, "windows")
        self.assertTrue((self.source / "AdaEditor.exe").is_file())

    def test_failed_replacement_restores_the_previous_install(self):
        studio.atomic_install(self.source, self.destination, "windows")
        (self.destination / "old.txt").write_text("previous")
        rename = Path.rename

        def fail_stage(path, target):
            if path.name == "staged":
                raise OSError("simulated locked destination")
            return rename(path, target)

        with patch.object(Path, "rename", fail_stage), self.assertRaises(OSError):
            studio.atomic_install(self.source, self.destination, "windows")
        self.assertEqual((self.destination / "old.txt").read_text(), "previous")
        self.assertEqual(list(self.destination.parent.glob(".ada-studio-*")), [])

    def test_rollback_failure_preserves_backup(self):
        studio.atomic_install(self.source, self.destination, "windows")
        rename = Path.rename

        def fail_stage_and_rollback(path, target):
            if path.name in ("staged", "previous"):
                raise OSError("simulated filesystem failure")
            return rename(path, target)

        with patch.object(Path, "rename", fail_stage_and_rollback), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(OSError):
            studio.atomic_install(self.source, self.destination, "windows")
        backups = list(self.destination.parent.glob(".ada-studio-*/previous"))
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / "AdaEditor.exe").is_file())

    def test_linux_distribution_requires_the_complete_runtime(self):
        source = self.root / "Linux"
        fixture(source, "linux")
        studio.atomic_install(source, self.destination, "linux")
        (source / "lib/liblore.so").unlink()
        with self.assertRaises(ToolError):
            studio.atomic_install(source, self.destination, "linux")
        self.assertTrue((self.destination / "lib/liblore.so").is_file())

    @unittest.skipUnless(os.name == "nt", "Requires Windows installer")
    def test_windows_cli_installs_a_real_distribution(self):
        command = [sys.executable, str(ROOT / "ada_tool.py"), "install", "studio", "--source", str(self.source),
                   "--destination", str(self.destination), "--no-shortcut"]
        result = subprocess.run(command, capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.destination / ".hidden").is_file())
        (self.source / "BuildSDK/sdk.json").unlink()
        result = subprocess.run(command, capture_output=True, text=True, timeout=45)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.destination / "BuildSDK/sdk.json").is_file())

    @unittest.skipUnless(sys.platform == "linux", "Requires Linux /proc")
    def test_linux_cli_installs_and_relocates_native_tools(self):
        source = self.root / "Linux Source"
        fixture(source, "linux")
        command = [sys.executable, str(ROOT / "ada_tool.py"), "install", "studio", "--source", str(source),
                   "--destination", str(self.destination), "--no-shortcut"]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = subprocess.run([str(self.destination / "adastudio"), "--version"], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Python", result.stdout + result.stderr)


class ArchiveTests(unittest.TestCase):
    def test_download_rejects_unexpected_schemes(self):
        with tempfile.TemporaryDirectory() as directory:
            ctx = Context(argparse.Namespace(), root=Path(directory))
            for url in ("ftp://example.invalid/tool.zip", "data:text/plain,unexpected"):
                with self.subTest(url=url), self.assertRaisesRegex(ToolError, "scheme"):
                    download(ctx, url, "tool.zip")

    def test_remote_redirect_cannot_switch_to_local_file_or_ftp(self):
        handler = DownloadRedirects()
        request = Request("https://example.invalid/tool.zip")
        for target in ("file:///private", "ftp://example.invalid/tool.zip"):
            with self.subTest(target=target), self.assertRaisesRegex(ToolError, "redirect scheme"):
                handler.redirect_request(request, None, 302, "Found", {}, target)

    def test_local_fixture_download_checks_and_preserves_matching_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.txt"
            source.write_bytes(b"fixture body")
            ctx = Context(argparse.Namespace(), root=Path(directory))
            with contextlib.redirect_stderr(io.StringIO()):
                result = download(ctx, source.as_uri(), "archive.bin", hashlib.sha256(source.read_bytes()).hexdigest())
            self.assertEqual(result.read_bytes(), b"fixture body")

    def test_zip_rejects_traversal_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, symlink in [("../escape", False), ("C:/escape", False), ("a\\..\\escape", False), ("link", True)]:
                archive = root / "bad.zip"
                with zipfile.ZipFile(archive, "w") as stream:
                    entry = zipfile.ZipInfo(name)
                    if symlink:
                        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    stream.writestr(entry, "../escape")
                # C:/ is only an absolute path on Windows.
                if name.startswith("C:") and os.name != "nt":
                    continue
                with self.subTest(name=name), self.assertRaises(ToolError):
                    extract_zip(archive, root / "out")
            self.assertFalse((root / "escape").exists())

    def test_tar_allows_internal_node_links_but_rejects_escaping_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "test.tar.gz"
            with tarfile.open(archive, "w:gz") as stream:
                entry = tarfile.TarInfo("../escape")
                entry.size = 1
                stream.addfile(entry, io.BytesIO(b"x"))
            with self.assertRaises(ToolError):
                extract_tar(archive, root / "out")
            self.assertFalse((root / "escape").exists())

    def test_download_checks_hash_before_replacing_cached_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.txt"
            source.write_text("download body")
            ctx = Context(argparse.Namespace(), root=root)
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(ToolError):
                download(ctx, source.as_uri(), "archive.zip", "0" * 64)
            self.assertFalse((ctx.cache / "downloads/archive.zip").exists())
            self.assertFalse((ctx.cache / "downloads/archive.zip.partial").exists())


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS ditto")
class MacOSCLIInstallationTests(unittest.TestCase):
    def test_install_debug_bundle_in_exact_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Source Кириллица & spaces.app"
            destination = root / "Applications/Ada Studio Debug.app"
            (source / "Contents/MacOS").mkdir(parents=True)
            executable = source / "Contents/MacOS/Ada Studio"
            executable.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            executable.chmod(0o755)
            (source / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "org.adaengine.editor",
                                                                       "CFBundleExecutable": "Ada Studio"}))
            result = subprocess.run([sys.executable, str(ROOT / "ada_tool.py"), "install", "studio", "--debug", "--source", str(source),
                                     "--destination", str(destination), "--no-shortcut"], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(destination / "Contents/MacOS/Ada Studio"), "installed"], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.stdout.strip(), "installed")


class StaticPreviewTests(unittest.TestCase):
    def test_spa_routes_resolve_and_api_requests_fail_explicitly(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "index.html").write_text("<h1>Playground</h1>")
            (root / "studio.js").write_text("// real frontend asset")
            server = ThreadingHTTPServer(("127.0.0.1", 0), partial(PreviewHandler, directory=directory))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            connection = HTTPConnection("127.0.0.1", server.server_port)
            try:
                connection.request("GET", "/projects/example")
                self.assertIn(b"Playground", connection.getresponse().read())
                connection.request("GET", "/studio/studio.js")
                self.assertIn(b"real frontend asset", connection.getresponse().read())
                connection.request("GET", "/v1/auth")
                response = connection.getresponse()
                self.assertEqual(response.status, 503)
                response.read()
            finally:
                connection.close()
                server.shutdown()
                server.server_close()
                thread.join()

    def test_nested_web_export_serves_both_studio_and_player(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "studio").mkdir()
            (root / "player").mkdir()
            (root / "studio/index.html").write_text("Studio HTML")
            (root / "player/AdaWebPlayer.wasm").write_bytes(b"\0asm")
            server = ThreadingHTTPServer(("127.0.0.1", 0), partial(PreviewHandler, directory=directory))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            connection = HTTPConnection("127.0.0.1", server.server_port)
            try:
                connection.request("GET", "/games")
                self.assertIn(b"Studio HTML", connection.getresponse().read())
                connection.request("GET", "/player/AdaWebPlayer.wasm")
                response = connection.getresponse()
                self.assertEqual(response.headers["Content-Type"], "application/wasm")
                self.assertEqual(response.read(), b"\0asm")
            finally:
                connection.close()
                server.shutdown()
                server.server_close()
                thread.join()


@unittest.skipUnless(shutil.which("swift"), "Requires Swift")
class SwiftBuildTests(unittest.TestCase):
    def test_build_logs_real_compiler_diagnostics_and_runs_binary(self):
        with tempfile.TemporaryDirectory(prefix="ada-tool-swift-") as directory:
            root = Path(directory)
            sources = root / "Sources/AdaEngine"
            sources.mkdir(parents=True)
            (root / "Package.swift").write_text('// swift-tools-version: 6.2\nimport PackageDescription\n'
                'let package = Package(name: "Fixture", targets: [.executableTarget(name: "AdaEngine")])\n')
            source = sources / "main.swift"
            source.write_text('#warning("ada-tool-compiler-warning")\nprint("Ada CLI fixture")\n')
            args = parser().parse_args(["build", "engine", "--debug", "--jobs", "1"])
            ctx = Context(args, root=root)
            if environment.swift_version(ctx) != PIN["swift"][ctx.host]:
                self.skipTest("Requires the host's pinned Swift version")
            progress = io.StringIO()
            with contextlib.redirect_stderr(progress):
                binary = studio.build(ctx, args)
            log = ctx.cache / "engine-debug-build.log"
            self.assertIn("ada-tool-compiler-warning", log.read_text())
            self.assertIn("Building for debugging", progress.getvalue())
            # The production engine command compiles a library target. Link this
            # executable fixture separately to verify the produced objects run.
            with contextlib.redirect_stderr(io.StringIO()):
                ctx.run([ctx.swift, "build", "--package-path", root, "--scratch-path", ctx.cache / "build/engine",
                         "--configuration", "debug", "--product", "AdaEngine"], capture=True)
            executable = binary / ("AdaEngine.exe" if os.name == "nt" else "AdaEngine")
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Ada CLI fixture", result.stdout)
            source.write_text('#error("ada-tool-compiler-failure")\n')
            diagnostics = io.StringIO()
            with contextlib.redirect_stderr(diagnostics), self.assertRaises(ToolError) as raised:
                studio.build(ctx, args)
            self.assertIn("ada-tool-compiler-failure", log.read_text(), str(raised.exception) + diagnostics.getvalue())


if __name__ == "__main__":
    unittest.main()
