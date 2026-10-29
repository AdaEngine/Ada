#!/usr/bin/env python3
"""Package a relocatable Windows x64 Studio ZIP and its SHA-256 checksum."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.check_output([str(arg) for arg in args], text=True, **kwargs).strip()


def imports(binary):
    output = run("llvm-readobj", "--coff-imports", binary)
    return set(re.findall(r"^\s*Name:\s*(\S+\.dll)\s*$", output, re.MULTILINE | re.IGNORECASE))


def bundle_dependencies(directory, binaries, search):
    """Resolve the full PE import closure; Windows API contracts stay on the OS."""
    system = Path(os.environ["SystemRoot"]) / "System32"
    visited = set()
    queue = list(binaries)
    while queue:
        binary = queue.pop()
        if binary in visited:
            continue
        visited.add(binary)
        for name in imports(binary):
            if name.lower().startswith(("api-ms-", "ext-ms-")):
                continue
            target = directory / name
            if target.is_file():
                queue.append(target)
                continue
            is_vc_runtime = name.lower().startswith(("msvcp", "vcruntime", "concrt"))
            if (system / name).is_file() and not is_vc_runtime:
                continue
            source = next((path / name for path in search if (path / name).is_file()), None)
            # VC runtime DLLs can come from the installed redistributable; unlike
            # Windows system DLLs they must accompany a portable application.
            if source is None and is_vc_runtime:
                source = system / name if (system / name).is_file() else None
            if source is None:
                if (system / name).is_file():
                    continue
                raise RuntimeError(f"Unresolved runtime dependency {name} required by {binary.name}")
            shutil.copy2(source, target)
            queue.append(target)


def clean_environment():
    environment = {key: value for key, value in os.environ.items()
                   if not key.upper().startswith(("ADAENGINE_", "ADA_STUDIO_", "ADA_MCP_", "TINT_", "SWAN_"))}
    for key in list(environment):
        if key.lower() == "path":
            del environment[key]
    environment["PATH"] = str(Path(os.environ["SystemRoot"]) / "System32")
    return environment


def smoke(directory):
    # Exercise the shipped executable with no Swift/toolchain/repository on PATH.
    # EOF is the ordinary MCP bridge shutdown path and needs neither GUI nor server.
    with tempfile.TemporaryDirectory(prefix="ada-release-smoke-") as work:
        shader = Path(work) / "smoke.wgsl"
        shader.write_text("@vertex fn main() -> @builtin(position) vec4<f32> { return vec4<f32>(0.0); }", encoding="utf-8")
        for command in [[directory / "AdaEditor.exe", "--editor-mcp-stdio"],
                        [directory / "adastudio.exe", "--help"],
                        [directory / "BuildSDK/AdaScript/gravity.exe", "--help"],
                        [directory / "AdaEngine_AdaRender.resources/tint.exe", shader, "--format", "wgsl"]]:
            result = subprocess.run([str(value) for value in command], input=b"", cwd=work,
                                    env=clean_environment(), capture_output=True, timeout=45)
            if result.returncode != 0:
                raise RuntimeError(f"Packaged {command[0].name} failed ({result.returncode}): {result.stderr.decode(errors='replace')}")
        cli = subprocess.run([str(directory / "adastudio.exe"), "--version", "--format", "json"],
                             cwd=work, env=clean_environment(), capture_output=True, timeout=45)
        if cli.returncode != 0 or not json.loads(cli.stdout).get("ok"):
            raise RuntimeError(f"Packaged CLI version failed: {cli.stderr.decode(errors='replace')}")


def package(binary_directory, compiler, tint, output, version, smoke_test=True, *, stage_only=False):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,79}", version):
        raise ValueError("Version must be a filename-safe release tag (1–80 characters).")
    metadata = json.loads(run("swiftc", "-print-target-info"))
    if metadata["target"]["triple"] != "x86_64-unknown-windows-msvc":
        raise RuntimeError("This package currently supports Windows x64 only.")
    output.mkdir(parents=True, exist_ok=True)
    name = f"AdaStudio-{version}-windows-x86_64"
    archive = output / (name + ".zip")
    installed = output / name
    if stage_only and installed.exists():
        raise FileExistsError(f"Standalone destination already exists: {installed}")
    with tempfile.TemporaryDirectory(prefix=".ada-release-", dir=output) as temporary:
        directory = Path(temporary) / name
        directory.mkdir()
        # Preserve Swift's CRT entry point and PE resources, but open as a desktop
        # application instead of creating an extra console on double-click.
        run("llvm-objcopy", "--subsystem=windows", binary_directory / "AdaEditor.exe", directory / "AdaEditor.exe")
        # A console PE has the same native implementation, but keeps stdout/stderr
        # and shell wait semantics. CLI dispatch happens before any UI/GPU setup.
        run("llvm-objcopy", "--subsystem=console", binary_directory / "AdaEditor.exe", directory / "adastudio.exe")
        for resource in binary_directory.glob("*.resources"):
            shutil.copytree(resource, directory / resource.name)
        for required in ["AdaEditor_AdaEditor.resources/Assets", "AdaEngine_AdaRender.resources"]:
            if not (directory / required).is_dir():
                raise RuntimeError(f"Required SwiftPM resources are missing: {required}")
        shutil.copy2(tint, directory / "AdaEngine_AdaRender.resources/tint.exe")
        spec = importlib.util.spec_from_file_location("stage_build_sdk", ROOT / "Editor/scripts/stage-build-sdk.py")
        sdk = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sdk)
        sdk.stage(ROOT, compiler, directory / "BuildSDK")

        runtime = [Path(path) for path in metadata["paths"]["runtimeLibraryPaths"]]
        # ICU and Foundation load some DLLs dynamically; keep the complete matching
        # Swift runtime instead of relying solely on the static PE import table.
        for path in runtime:
            for library in path.glob("*.dll"):
                if not (directory / library.name).exists():
                    shutil.copy2(library, directory)
        artifacts = binary_directory.parent.parent / "artifacts"
        for name_dll in ["dxcompiler.dll", "dxil.dll", "d3dcompiler_47.dll"]:
            candidates = [path for path in artifacts.rglob(name_dll) if "windows_x86_64" in str(path)]
            source = binary_directory / name_dll
            if not source.is_file() and candidates:
                source = candidates[0]
            if not source.is_file():
                raise RuntimeError(f"Dawn runtime is missing: {name_dll}")
            shutil.copy2(source, directory)
        search = [binary_directory] + runtime + [Path(path) for path in os.environ.get("PATH", "").split(os.pathsep) if path]
        binaries = list(directory.glob("*.dll")) + [directory / "AdaEditor.exe", directory / "adastudio.exe", directory / "BuildSDK/AdaScript/gravity.exe",
                                                  directory / "AdaEngine_AdaRender.resources/tint.exe"]
        bundle_dependencies(directory, binaries, search)
        for helper in [directory / "BuildSDK/AdaScript/gravity.exe", directory / "AdaEngine_AdaRender.resources/tint.exe"]:
            bundle_dependencies(helper.parent, [helper], [directory] + search)

        notices = directory / "ThirdPartyNotices"
        tint_pin = json.loads((ROOT / "Tools/Tint/toolchain.json").read_text())
        dependencies = list((binary_directory.parent.parent / "checkouts").iterdir()) + [compiler,
            tint.parent.parent.parent / tint_pin["revision"] / "source"]
        dependencies += list((ROOT / ".build-tools").glob("adamcp-*"))
        for dependency in dependencies:
            if dependency.is_dir():
                for file in dependency.iterdir():
                    if file.is_file() and file.name.upper().startswith(("LICENSE", "NOTICE", "COPYING", "COPYRIGHT")):
                        destination = notices / dependency.name
                        destination.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(file, destination)
        swift_notice = notices / "Swift"
        swift_notice.mkdir(parents=True, exist_ok=True)
        swift_tag = metadata["swiftCompilerTag"]
        if not re.fullmatch(r"swift-[0-9.]+-RELEASE", swift_tag):
            raise RuntimeError("Use an official Swift release toolchain to package Studio.")
        with urllib.request.urlopen(f"https://raw.githubusercontent.com/swiftlang/swift/{swift_tag}/LICENSE.txt", timeout=30) as response:
            (swift_notice / "LICENSE.txt").write_bytes(response.read())
        shutil.copy2(ROOT / "LICENSE", directory)
        shutil.copy2(ROOT / "Tools/Tint/toolchain.json", directory / "tint-toolchain.json")
        (directory / "release.json").write_text(json.dumps({"version": version, "distribution": "standalone", "commit": run("git", "-C", ROOT, "rev-parse", "HEAD"),
                                                           "swift": metadata["compilerVersion"], "target": metadata["target"]["triple"]}, indent=2) + "\n")
        (directory / "README.txt").write_text(
            "Ada Studio for Windows x64\n\nExtract the entire ZIP, then open AdaEditor.exe.\n"
            "AdaPlayer: AdaEditor.exe --ada-player\n\n"
            "CLI: adastudio.exe --help\n"
            "     adastudio.exe validate --project D:\\Games\\MyGame --format json\n\n"
            "The Swift runtime, graphics DLLs, shader compiler and AdaScript source SDK are included.\n"
            "Building native Swift projects needs the Swift toolchain and Visual Studio C++ tools.\n"
            "Game export also needs Python/CMake; Web and Android use WSL and their SDKs.\n"
            "Node.js/uv and provider sign-in are required by agents using those distributions.\n"
            "Windows binaries are currently unsigned.\n", encoding="utf-8")
        if stage_only:
            if smoke_test:
                smoke(directory)
            shutil.move(str(directory), installed)
            print(installed)
            return installed
        staged_archive = Path(temporary) / archive.name
        with zipfile.ZipFile(staged_archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zipped:
            for file in sorted(directory.rglob("*")):
                if file.is_file():
                    zipped.write(file, file.relative_to(directory.parent))
        if smoke_test:
            with tempfile.TemporaryDirectory(prefix="ada-release-relocated-") as relocated:
                with zipfile.ZipFile(staged_archive) as zipped:
                    zipped.extractall(relocated)
                smoke(Path(relocated) / name)
        os.replace(staged_archive, archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n", encoding="ascii")
    print(archive)
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", required=True, type=Path)
    parser.add_argument("--compiler-root", required=True, type=Path)
    parser.add_argument("--tint", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--version", required=True)
    parser.add_argument("--stage-only", action="store_true", help="Prepare and verify a complete standalone directory without creating a ZIP")
    args = parser.parse_args()
    package(args.bin.resolve(), args.compiler_root.resolve(), args.tint.resolve(), args.output.resolve(), args.version, stage_only=args.stage_only)


if __name__ == "__main__":
    main()
