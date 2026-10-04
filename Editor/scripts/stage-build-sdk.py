#!/usr/bin/env python3
"""Stage the relocatable source build SDK for standalone macOS Ada Studio."""

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
        candidates = [engine / "Editor/.build/checkouts/gravity-lang", engine / ".build/checkouts/gravity-lang"]
        if os.environ.get("BUILD_DIR"):
            candidates.append(Path(os.environ["BUILD_DIR"]).parents[1] / "SourcePackages/checkouts/gravity-lang")
    for candidate in candidates:
        if (candidate / "tools/aot_build.py").is_file():
            return candidate.resolve()
    raise RuntimeError("AdaScript AOT compiler source not found. Set ADAENGINE_GRAVITY_PACKAGE_PATH for the standalone build.")


def copy_inputs(root, destination, names):
    destination.mkdir(parents=True)
    ignored = shutil.ignore_patterns(".git", ".build", ".codegraph", "__pycache__", ".DS_Store", "*.o", "*.a")
    for name in names:
        source = root / name
        if source.is_dir():
            shutil.copytree(source, destination / name, ignore=ignored)
        elif source.is_file():
            shutil.copy2(source, destination / name)


def stage(engine, compiler, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".ada-sdk-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "BuildSDK"
        staged.mkdir()
        copy_inputs(engine, staged / "AdaEngine", ["Package.swift", "Package.resolved", ".swiftlint.yml", "LICENSE", "NOTICE",
                                                   "Sources", "Plugins", "Tools", "Tests", "Demos", "Assets"])
        copy_inputs(compiler, staged / "AdaScript", ["Package.swift", "Package.resolved", "LICENSE", "Makefile", "src", "binding",
                                                    "tools", "Tests", "examples", "gravity"])
        host = staged / "AdaScript/gravity"
        if not host.is_file() or not os.access(host, os.X_OK):
            subprocess.run(["/usr/bin/make", "-j4"], cwd=staged / "AdaScript", check=True)
        subprocess.run([str(host), "--help"], stdout=subprocess.DEVNULL, check=True)
        for generated in (staged / "AdaScript/src").rglob("*.o"):
            generated.unlink()
        (staged / "sdk.json").write_text(json.dumps({"schemaVersion": 1, "engine": "AdaEngine", "compiler": "AdaScript"}) + "\n")
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
