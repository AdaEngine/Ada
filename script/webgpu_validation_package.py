#!/usr/bin/env python3
"""Stage focused production test sources without building unrelated demo/editor targets."""
import argparse
import json
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
destination = args.destination.resolve()
sources = destination / "Tests/RenderingValidationTests"
sources.mkdir(parents=True, exist_ok=True)
for relative in ["Tests/AdaUtilsTests/TintToolchainTests.swift", "Tests/AdaRenderTests/TintShaderCompilerTests.swift", "Tests/AdaRenderTests/WGSLReflectionTests.swift", "Tests/AdaEngineTests/SpriteMetalRenderingTests.swift"]:
    source = root / relative
    shutil.copy2(source, sources / source.name)
modules = ["AdaApp", "AdaCorePipelines", "AdaECS", "AdaRender", "AdaSprite", "AdaTilemap", "AdaTransform", "AdaUtils", "Math"]
dependencies = ',\n'.join('.product(name: ' + json.dumps(module) + ', package: "AdaEngine")' for module in modules)
(destination / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "RenderingValidation", platforms: [.macOS(.v15)], dependencies: [
    .package(name: "AdaEngine", path: ''' + json.dumps(str(root)) + ''')
], targets: [.testTarget(name: "RenderingValidationTests", dependencies: [
''' + dependencies + '\n])])\n')
print(destination)
