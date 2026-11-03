#!/usr/bin/env python3
"""Fetch pinned meshoptimizer source and build the offline-only scan adapter."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REVISION = "9e1f07b159d3cb777f1c67ed31fc11fd117986f4"  # v1.3
EXPECTED_SHA256 = {
    "src/meshoptimizer.h": "e3688ef553f603391747895a5c221ef1528574cc7f8173782417a96cb531f61b",
    "src/clusterizer.cpp": "a2775edf77d86a9a5f0ca82f4635ce6ce741bbda79fd9a652ffc8c5dd61d3b0e",
    "src/allocator.cpp": "d2cc48691fe2f4c6d097bf7a766389cfb7f83ca14a5f747e3944332656d02254",
    "src/simplifier.cpp": "719303b6970398631e30724e8eebc6cd2e7e08b67fe8ab7cbf7eecafdaa08616",
    "src/indexgenerator.cpp": "f362cdcd8af10016333bf699347a9364335987f413f061e5b7e8cafe3b498948",
    "LICENSE.md": "f03037ca7bad1e3eb7f4a63fa6084a8baabd5ba30d3c239a9a7f35705d873e26",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="clang++")
    parser.add_argument("--output", type=Path, default=ROOT / ".build-tools/meshlet-builder")
    args = parser.parse_args()
    output = args.output.resolve()
    source = output / "meshoptimizer-v1.3"
    source.mkdir(parents=True, exist_ok=True)
    files = list(EXPECTED_SHA256)
    hashes = {}
    for relative in files:
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        value = urllib.request.urlopen(f"https://raw.githubusercontent.com/zeux/meshoptimizer/{REVISION}/{relative}").read()
        if hashlib.sha256(value).hexdigest() != EXPECTED_SHA256[relative]:
            raise ValueError(f"Pinned source hash mismatch: {relative}")
        target.write_bytes(value)
        hashes[relative] = hashlib.sha256(value).hexdigest()
    binary = output / ("MeshletScan.exe" if os.name == "nt" else "MeshletScan")
    command = [args.compiler, "-std=c++17", "-O2", "-I", str(source / "src"),
               str(ROOT / "Tools/Meshlets/MeshletScan.cpp"), str(source / "src/clusterizer.cpp"),
               str(source / "src/allocator.cpp"), "-o", str(binary)]
    if os.name == "nt":
        command += ["-fms-runtime-lib=dll", "-D_MT", "-D_DLL", "-lucrt", "-lvcruntime", "-lmsvcrt", "-lmsvcprt",
                    "-Xlinker", "/NODEFAULTLIB:libcmt"]
    subprocess.run(command, check=True)
    lod_binary = output / ("MeshletLOD.exe" if os.name == "nt" else "MeshletLOD")
    lod_command = [args.compiler, "-std=c++17", "-O2", "-I", str(source / "src"), str(ROOT / "Tools/Meshlets/MeshletLOD.cpp"),
                   *(str(source / "src" / name) for name in ["clusterizer.cpp", "allocator.cpp", "simplifier.cpp", "indexgenerator.cpp"]), "-o", str(lod_binary)]
    if os.name == "nt":
        lod_command += ["-fms-runtime-lib=dll", "-D_MT", "-D_DLL", "-lucrt", "-lvcruntime", "-lmsvcrt", "-lmsvcprt", "-Xlinker", "/NODEFAULTLIB:libcmt"]
    subprocess.run(lod_command, check=True)
    manifest = dict(version="1.3", revision=REVISION, source="https://github.com/zeux/meshoptimizer",
                    license="MIT", sourceSHA256=hashes, toolSHA256=hashlib.sha256(binary.read_bytes()).hexdigest(), command=command,
                    lodToolSHA256=hashlib.sha256(lod_binary.read_bytes()).hexdigest(), lodCommand=lod_command)
    (output / "build.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(binary)


if __name__ == "__main__":
    main()
