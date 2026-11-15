#!/usr/bin/env python3
"""Stage the relocatable source build SDK for standalone desktop Ada Studio."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def compiler_root(engine, explicit):
    if explicit:
        candidates = [Path(explicit)]
    else:
        candidates = [engine / "Sources/gravity-lang", engine / "Editor/.build/checkouts/gravity-lang", engine / ".build/checkouts/gravity-lang"]
        if os.environ.get("BUILD_DIR"):
            # Archive build products are nested deeper than ordinary Build/Products.
            candidates.extend(parent / "SourcePackages/checkouts/gravity-lang"
                              for parent in Path(os.environ["BUILD_DIR"]).parents)
    for candidate in candidates:
        if (candidate / "tools/aot_build.py").is_file():
            return candidate.resolve()
    raise RuntimeError("AdaScript AOT compiler source not found. Set ADAENGINE_GRAVITY_PACKAGE_PATH for the standalone build.")


def copy_inputs(root, destination, names, excluded=()):
    destination.mkdir(parents=True)
    ignored = shutil.ignore_patterns(
        ".git", ".build*", ".codegraph", "__pycache__", ".DS_Store", "*.o", "*.a",
        "dist", "build", "node_modules", "*.app", "*.dSYM", "*.xcarchive", *excluded
    )
    for name in names:
        source = root / name
        if source.is_dir():
            shutil.copytree(source, destination / name, ignore=ignored)
        elif source.is_file():
            shutil.copy2(source, destination / name)


def stage(engine, compiler, destination):
    saga_override = os.environ.get("ADAENGINE_SAGA_PACKAGE_PATH")
    saga = Path(saga_override).resolve() if saga_override else None
    if saga is not None and not (saga / "Package.swift").is_file():
        raise RuntimeError(f"Local SAGA checkout is missing Package.swift: {saga}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".ada-sdk-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "BuildSDK"
        staged.mkdir()
        copy_inputs(engine, staged / "AdaEngine", ["Package.swift", "Package.resolved", ".swiftlint.yml", "LICENSE", "NOTICE",
                                                   "Sources", "Plugins", "Tools", "Tests", "Assets", "script", "Editor/StudioCore"],
                    excluded=("glslang", "SPIRVCompiler", "SPIRV-Cross"))
        if saga is not None:
            copy_inputs(saga, staged / "SAGA", ["Package.swift", "LICENSE", "NOTICE", "Sources", "Tests", "web"])
        # These checked-in browser modules are required by the Web export plugin.
        # Ordinary generated dist directories remain excluded from the SDK.
        browser_runtime = Path("Plugins/AdaWebExportPlugin/BrowserWASIShim/dist")
        if (engine / browser_runtime).is_dir():
            modules = sorted(file.name for file in (engine / browser_runtime).glob("*.js"))
            copy_inputs(engine / browser_runtime, staged / "AdaEngine" / browser_runtime, modules)
        copy_inputs(compiler, staged / "AdaScript", ["Package.swift", "Package.resolved", "LICENSE", "Makefile", "src", "binding",
                                                    "tools", "Tests", "examples", "gravity", "gravity.exe"])
        host = staged / "AdaScript" / ("gravity.exe" if os.name == "nt" else "gravity")
        if not host.is_file() or not os.access(host, os.X_OK):
            if os.name == "nt":
                raise RuntimeError("Build gravity.exe with script/ensure_windows_export_tools.py before staging the Windows SDK.")
            subprocess.run(["/usr/bin/make", "-j4"], cwd=staged / "AdaScript", check=True)
        subprocess.run([str(host), "--help"], stdout=subprocess.DEVNULL, check=True)
        for generated in (staged / "AdaScript/src").rglob("*.o"):
            generated.unlink()
        manifest = {"schemaVersion": 1, "engine": "AdaEngine", "compiler": "AdaScript"}
        if saga is not None:
            manifest["saga"] = "SAGA"
        (staged / "sdk.json").write_text(json.dumps(manifest) + "\n")
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(staged), destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-root", required=True, type=Path)
    parser.add_argument("--compiler-root", default=os.environ.get("ADAENGINE_GRAVITY_PACKAGE_PATH"))
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    engine = args.engine_root.resolve()
    if not (engine / "Package.swift").is_file():
        parser.error("engine root must contain Package.swift")
    stage(engine, compiler_root(engine, args.compiler_root), args.output.resolve())


if __name__ == "__main__":
    main()
