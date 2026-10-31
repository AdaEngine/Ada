#!/usr/bin/env python3
"""Package a relocatable Linux Studio with resources, Swift runtime and source SDK."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

from ensure_linux_lore import ensure as ensure_lore

ROOT = Path(__file__).resolve().parents[1]


def package(binary_directory, compiler, tint, swan, dawn, output, version):
    if not version or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_" for c in version):
        raise ValueError("Version must be a filename component")
    metadata = json.loads(subprocess.check_output(["swift", "-print-target-info"], text=True))
    triple = metadata["target"]["triple"]
    if "linux" not in triple:
        raise RuntimeError("Run this packager with a Linux Swift toolchain")
    if Path(dawn).is_absolute() or ".." in Path(dawn).parts:
        raise ValueError("Dawn artifact must be relative to Swan")
    output.mkdir(parents=True, exist_ok=True)
    name = "AdaStudio-" + version + "-" + triple.split("-")[0] + "-linux"
    destination = output / name
    archive = output / (name + ".tar.gz")
    if destination.exists() or archive.exists():
        raise FileExistsError("Distribution already exists: " + str(destination))
    with tempfile.TemporaryDirectory(prefix=".ada-linux-", dir=output) as work:
        directory = Path(work) / name
        directory.mkdir()
        for executable in ("AdaEditor", "gravity-lsp", "AdaPackageTool"):
            shutil.copy2(binary_directory / executable, directory / executable)
        for resource in binary_directory.glob("*.resources"):
            shutil.copytree(resource, directory / resource.name)
        for required in ("AdaEditor_AdaEditor.resources/Assets", "AdaEngine_AdaRender.resources"):
            if not (directory / required).is_dir():
                raise RuntimeError("Missing SwiftPM resources: " + required)
        shutil.copy2(tint, directory / "AdaEngine_AdaRender.resources/tint")
        runtime = directory / "lib"
        runtime.mkdir()
        lore_sdk = ensure_lore()
        shutil.copy2(lore_sdk / "liblore.so", runtime / "liblore.so")
        lore_notices = directory / "ThirdPartyNotices/Lore"
        lore_notices.mkdir(parents=True, exist_ok=True)
        for notice in ("LICENSE.txt", "THIRD-PARTY-NOTICES.txt"):
            shutil.copy2(lore_sdk / notice, lore_notices / notice)
        for path in metadata["paths"]["runtimeLibraryPaths"]:
            for library in Path(path).glob("*.so*"):
                if not (runtime / library.name).exists():
                    shutil.copy2(library, runtime / library.name)
        spec = importlib.util.spec_from_file_location("stage_build_sdk", ROOT / "Editor/scripts/stage-build-sdk.py")
        sdk = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sdk)
        sdk.stage(ROOT, compiler, directory / "BuildSDK")
        sdk.copy_inputs(swan, directory / "BuildSDK/Swan", ["Package.swift", "LICENSE", "Sources"])
        shutil.copytree(swan / dawn, directory / "BuildSDK/Swan/DawnLinux.artifactbundle")
        (directory / "ada-studio").write_text('''#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="$root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export ADA_STUDIO_SDK="$root/BuildSDK"
export ADAENGINE_PACKAGE_PATH="$root/BuildSDK/AdaEngine"
export ADAENGINE_GRAVITY_PACKAGE_PATH="$root/BuildSDK/AdaScript"
export ADAENGINE_SWAN_PACKAGE_PATH="$root/BuildSDK/Swan"
export SWAN_LOCAL_DAWN=DawnLinux.artifactbundle
export ADAENGINE_SKIP_SWIFTLINT=1
export TINT_EXECUTABLE="$root/AdaEngine_AdaRender.resources/tint"
exec "$root/AdaEditor" "$@"
''', encoding="utf-8")
        (directory / "ada-studio").chmod(0o755)
        shutil.copy2(ROOT / "LICENSE", directory / "LICENSE-AdaEngine")
        # Swiftly's `swift` is a launcher, so derive the actual toolchain from compiler metadata.
        toolchain = Path(metadata["paths"]["runtimeResourcePath"]).parent.parent
        swift_license = toolchain / "share/swift/LICENSE.txt"
        shutil.copy2(swift_license, directory / "LICENSE-Swift.txt")
        (directory / "README.txt").write_text(
            "Ada Studio Standalone for Linux\n\nRun ./ada-studio from this folder.\n"
            "Requires an X11 desktop (or XWayland), Vulkan drivers, libX11, libpulse and Zenity.\n"
            "Built on the current host: use a distribution with compatible glibc/libstdc++.\n"
            "Swift runtime, resources, Tint, AdaScript compiler and source BuildSDK are bundled.\n"
            "Building Swift games also requires Swift 6.3.2, clang, pkg-config, libx11-dev and libasound2-dev.\n"
            "Web/Android export, remote AdaPlayer, local agents and debugger parity are not validated on Linux.\n",
            encoding="utf-8",
        )
        # Resolve every executable with the bundled runtime, detecting missing host dependencies.
        environment = os.environ | {"LD_LIBRARY_PATH": str(runtime)}
        for executable in (directory / "AdaEditor", directory / "gravity-lsp", directory / "AdaPackageTool",
                           directory / "BuildSDK/AdaScript/gravity", directory / "AdaEngine_AdaRender.resources/tint", runtime / "liblore.so"):
            result = subprocess.run(["ldd", str(executable)], env=environment, text=True, capture_output=True)
            if "not found" in result.stdout or result.returncode not in (0, 1):
                raise RuntimeError("Unresolved Linux dependencies: " + result.stdout + result.stderr)
        subprocess.run([str(directory / "BuildSDK/AdaScript/gravity"), "--help"], env=environment, check=True, stdout=subprocess.DEVNULL)
        shutil.move(str(directory), destination)
    with tarfile.open(archive, "w:gz") as bundle:
        bundle.add(destination, arcname=name)
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    checksum = digest.hexdigest()
    archive.with_suffix(archive.suffix + ".sha256").write_text(checksum + "  " + archive.name + "\n", encoding="utf-8")
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("binary-directory", "compiler", "tint", "swan", "output"):
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--dawn", default="DawnLinux.artifactbundle")
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    print(package(args.binary_directory.resolve(), args.compiler.resolve(), args.tint.resolve(), args.swan.resolve(),
                  args.dawn, args.output.resolve(), args.version))


if __name__ == "__main__":
    main()
