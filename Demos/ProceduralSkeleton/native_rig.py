"""Build the native AdaAssets rig author and its production-source tests without renderer dependencies.

The isolated SwiftPM package snapshots the checked-out Math, AdaAssets GLTF and
procedural sources verbatim. It has no third-party dependencies or downloads.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

PROJECT = Path(__file__).resolve().parent
ENGINE = PROJECT.parents[1]
STAGE = ENGINE / ".build-tools/skeleton-rig"


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)


def stage():
    groups = {
        "Math": [ENGINE / "Sources/Math"],
        "AdaAssets": [ENGINE / "Sources/AdaAssets/GLTF", ENGINE / "Sources/AdaAssets/Procedural"],
        "SkeletonRig": [PROJECT / "NativeRig"],
        "AdaAnimation": [ENGINE / "Sources/AdaAnimation/Skeletal"],
    }
    for module, folders in groups.items():
        for folder in folders:
            for source in folder.rglob("*.swift"):
                write(STAGE / "Sources" / module / source.name, source.read_bytes())
    for name in ["ProceduralModelTests.swift", "ProceduralRigTests.swift"]:
        source = ENGINE / "Tests/AdaAssetsTests" / name
        write(STAGE / "Tests/AdaAssetsTests" / name, source.read_bytes())
    scope = PROJECT / "Validation/StandaloneAssetScope.swift"
    write(STAGE / "Sources/AdaAssets/StandaloneAssetScope.swift", scope.read_bytes())
    sampler = (ENGINE / "Sources/AdaAnimation/KeyframeSampler.swift").read_text(encoding="utf-8")
    interpolation = "import Math\n\n" + sampler[sampler.index("func slerpQuat("):]
    write(STAGE / "Sources/AdaAnimation/SkeletalQuaternionInterpolation.swift", interpolation.encode())
    walk_test = PROJECT / "Validation/SkeletonWalkTests.swift"
    write(STAGE / "Tests/SkeletonRigTests/SkeletonWalkTests.swift", walk_test.read_bytes())
    manifest = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "SkeletonRigStudy", targets: [
    .target(name: "Math"),
    .target(name: "AdaAssets", dependencies: ["Math"]),
    .target(name: "AdaAnimation", dependencies: ["Math"]),
    .executableTarget(name: "SkeletonRig", dependencies: ["AdaAssets", "Math"]),
    .testTarget(name: "AdaAssetsTests", dependencies: ["AdaAssets", "Math"]),
    .testTarget(name: "SkeletonRigTests", dependencies: ["SkeletonRig", "AdaAssets", "AdaAnimation", "Math"])
])
'''
    write(STAGE / "Package.swift", manifest.encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["test", "generate"])
    args = parser.parse_args()
    stage()
    swift = shutil.which("swift")
    if not swift:
        raise RuntimeError("Install the repository's compatible Swift toolchain first")
    if args.action == "test":
        subprocess.run([swift, "test", "--package-path", str(STAGE)], check=True)
    else:
        output = PROJECT / "Assets/Models/Skeleton-Walk.glb"
        environment = dict(os.environ, SKELETON_RIG_RESOURCE_ROOT=str(PROJECT / "Assets"))
        result = subprocess.run([swift, "run", "--package-path", str(STAGE), "SkeletonRig",
                                 str(PROJECT / "Assets/Models/Skeleton.glb"), str(output),
                                 str(PROJECT / "Assets/Models/Skeleton-Walk-samples.glb")],
                                check=True, capture_output=True, text=True, env=environment)
        print(result.stderr, end="")
        print(result.stdout, end="")
        evidence = PROJECT / "Evidence/Rig"
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / "generation.json").write_text(result.stdout, encoding="utf-8")


if __name__ == "__main__":
    main()
