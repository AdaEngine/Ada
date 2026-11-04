"""Develop/test the AdaScript model bridge in an isolated native VM harness.

The Swift build is a developer check, not a step required by an iPad recipe.
The app bundles this bridge ahead of time; recipe execution uses the bytecode VM.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

from native_rig import ENGINE, PROJECT, write

STAGE = ENGINE / ".build-tools/skeleton-script"


def stage(gravity):
    groups = {
        "Math": [ENGINE / "Sources/Math"],
        "AdaAssets": [ENGINE / "Sources/AdaAssets/GLTF", ENGINE / "Sources/AdaAssets/Procedural", ENGINE / "Sources/AdaAssets/Voxel"],
        "AdaScriptCompilerCore": [ENGINE / "Sources/AdaScriptCompilerCore"],
    }
    for module, folders in groups.items():
        for folder in folders:
            for source in folder.rglob("*.swift"):
                write(STAGE / "Sources" / module / source.name, source.read_bytes())
    scripting = ["AdaScriptModelGenerator.swift", "AdaScriptModelRigBuilder.swift", "AdaScriptGeneratorRunner.swift",
                 "AdaScriptGeneratorDelegate.swift", "AdaScriptCommunityPolicy.swift", "AdaScriptRuntimeCoordinator.swift",
                 "AdaScriptStandardLibrary.swift", "GravityScriptModule.swift", "AdaScriptSoundGenerator.swift", "AdaScriptSpriteGenerator.swift", "AdaScriptVoxelGenerator.swift"]
    for name in scripting:
        path = ENGINE / "Sources/AdaScripting" / name
        if path.exists():
            write(STAGE / "Sources/AdaScripting" / name, path.read_bytes())
    identifiers = (ENGINE / "Sources/AdaScripting/AdaScriptIdentifiers.swift").read_text(encoding="utf-8")
    identifiers = identifiers[:identifiers.index("\n#if canImport(GravityAOT)\nfinal class NativeIdentifiersHost")]
    write(STAGE / "Sources/AdaScripting/AdaScriptIdentifiers.swift", identifiers.encode())
    test_runner = (ENGINE / "Sources/AdaScripting/AdaScriptTestRunner.swift").read_text(encoding="utf-8")
    write(STAGE / "Sources/AdaScripting/AdaScriptTestCase.swift", test_runner[:test_runner.index("/// The outcome")].encode())
    write(STAGE / "Sources/AdaAssets/StandaloneAssetScope.swift", (PROJECT / "Validation/StandaloneAssetScope.swift").read_bytes())
    for name in ["AdaScriptModelGeneratorTests.swift", "AdaScriptModelRigTests.swift", "AdaScriptMediaGeneratorTests.swift", "AdaScriptVoxelGeneratorTests.swift"]:
        path = ENGINE / "Tests/AdaScriptingTests" / name
        if path.exists():
            write(STAGE / "Tests/AdaScriptingTests" / name, path.read_bytes())
    main = PROJECT / "Validation/ScriptRigMain.swift"
    write(STAGE / "Sources/ScriptRig/Main.swift", main.read_bytes() if main.exists() else b'@main struct Main { static func main() {} }\n')
    manifest = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ScriptRigStudy", dependencies: [.package(name: "gravity-lang", path: GRAVITY_PATH)], targets: [
    .target(name: "Math"),
    .target(name: "AdaAssets", dependencies: ["Math"]),
    .target(name: "AdaScriptCompilerCore"),
    .target(name: "AdaScripting", dependencies: ["AdaAssets", "Math", "AdaScriptCompilerCore", .product(name: "Gravity", package: "gravity-lang")]),
    .executableTarget(name: "ScriptRig", dependencies: ["AdaAssets", "AdaScriptCompilerCore", "AdaScripting"]),
    .testTarget(name: "AdaScriptingTests", dependencies: ["AdaAssets", "AdaScripting"])
])
'''.replace("GRAVITY_PATH", json.dumps(str(gravity), ensure_ascii=False))
    write(STAGE / "Package.swift", manifest.encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["bootstrap", "test", "generate", "run"])
    parser.add_argument("--gravity", type=Path, default=None)
    parser.add_argument("--runtime-path", help="Override PATH for the prebuilt VM runner, for a compiler-free execution check")
    args = parser.parse_args()
    if args.runtime_path and args.action != "run":
        parser.error("--runtime-path is only valid with the prebuilt 'run' action")
    gravity = args.gravity or Path(os.environ.get("ADAENGINE_GRAVITY_PACKAGE_PATH", ENGINE / "Sources/gravity-lang"))
    if args.action != "run":
        stage(gravity.resolve())
    swift = shutil.which("swift")
    if args.action != "run" and not swift:
        raise RuntimeError("The developer harness requires Swift; the bundled iPad runtime does not")
    if args.action == "bootstrap":
        command = [swift, "build", "--package-path", str(STAGE), "--jobs", "2", "--target", "Gravity"]
    elif args.action == "test":
        command = [swift, "test", "--package-path", str(STAGE), "--jobs", "2"]
    else:
        source = (PROJECT / "Generators/Skeleton.ada").read_text(encoding="utf-8")
        source = source.replace("func build(m) {", "func buildStaticSkeleton(m) {", 1)
        source = source.replace("Static multipart study, not a skinned mesh.", "Base geometry; the rig recipe follows below.", 1)
        # Expand the static author's packed calls in the composed, reviewable rig recipe.
        source = "\n".join(line if line.lstrip().startswith("//") else line.replace("; ", ";\n    ") for line in source.splitlines()) + "\n"
        source = source.replace("}\nfunc ", "}\n\nfunc ")
        source = "// Geometry, rig, weights and walk are authored by this interpreted AdaScript recipe.\n" + source
        source += "\n" + (PROJECT / "Generators/SkeletonRigRecipe.ada").read_text(encoding="utf-8")
        write(PROJECT / "Generators/Skeleton-Rig.ada", source.encode())
        arguments = [str(PROJECT / "Generators/Skeleton-Rig.ada"), str(PROJECT / "Assets/Models/Skeleton-AdaScript.glb")]
        if args.action == "run":
            name = "ScriptRig.exe" if os.name == "nt" else "ScriptRig"
            candidates = [p for p in (STAGE / ".build").rglob(name) if p.is_file() and p.parent.name == "debug"]
            if len(candidates) != 1:
                raise RuntimeError("Build the developer runner once before running it without a compiler")
            command = [str(candidates[0]), *arguments]
        else:
            command = [swift, "run", "--package-path", str(STAGE), "ScriptRig", *arguments]
    environment = dict(os.environ)
    if args.runtime_path:
        environment["PATH"] = args.runtime_path
        assert shutil.which("swift", path=args.runtime_path) is None
        assert shutil.which("swiftc", path=args.runtime_path) is None
    subprocess.run(command, check=True, env=environment)


if __name__ == "__main__":
    main()
