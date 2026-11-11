#!/usr/bin/env python3
"""Stage production Shader Graph CPU/VM/AOT tests in a small, relocatable package."""
import argparse
import json
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("destination", type=Path)
destination = parser.parse_args().destination.resolve()
tests = destination / "Tests/ShaderGraphValidationTests"
tests.mkdir(parents=True, exist_ok=True)
for relative in [
    "Tests/AdaRenderTests/ShaderGraphTests.swift",
    "Tests/AdaRenderTests/ShaderGraphProgramTests.swift",
    "Tests/AdaRenderTests/ShaderGraphMaterialTests.swift",
    "Tests/AdaRenderTests/ShaderGraphEffectTests.swift",
    "Tests/AdaRenderTests/ShaderGraphArchiveTests.swift",
    "Tests/AdaECSTests/DynamicQueryTests.swift",
    "Tests/AdaSceneTests/ShaderGraphModelSourceTests.swift",
    "Tests/AdaSceneTests/ShaderGraphPrimitiveSourceTests.swift",
    "Tests/AdaScriptingTests/ShaderGraphScriptTests.swift",
    "Tests/AdaEngineTests/PluginLoadingTests.swift",
    "Tests/AdaShaderGraphBakerTests/ShaderGraphBakerTests.swift",
    "Tests/AdaShaderGraphBakerTests/WebExportSupportTests.swift",
]:
    source = root / relative
    shutil.copy2(source, tests / source.name)
shutil.copytree(root / "Tests/AdaScriptAOTFixture", destination / "Tests/AdaScriptAOTFixture", dirs_exist_ok=True)
shutil.copytree(root / "Plugins/AdaShaderGraphBaker", destination / "Sources/AdaShaderGraphBaker", dirs_exist_ok=True)
shutil.copy2(root / "Plugins/AdaWebExportPlugin/WebExportSupport.swift", destination / "Sources/AdaShaderGraphBaker/WebExportSupport.swift")
modules = ["AdaApp", "AdaCorePipelines", "AdaECS", "AdaRender", "AdaScene", "AdaScriptCompilerCore", "AdaScripting", "AdaSprite", "AdaUtils", "AdaTransform", "Math"]
dependencies = ",\n".join('.product(name: ' + json.dumps(name) + ', package: "AdaEngine")' for name in modules)
excluded = sorted(file.name for file in (root / "Tests/AdaScriptAOTFixture").glob("*.ada"))
(destination / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ShaderGraphScriptingValidation", platforms: [.macOS(.v15)], dependencies: [
    .package(name: "AdaEngine", path: ''' + json.dumps(str(root)) + '''),
    .package(name: "gravity-lang", path: ''' + json.dumps(str(root / "Sources/gravity-lang")) + ''')
], targets: [
    .executableTarget(name: "AdaShaderGraphBaker", dependencies: [
        .product(name: "AdaWGSLCompiler", package: "AdaEngine"),
        .product(name: "AdaRender", package: "AdaEngine"), .product(name: "AdaCorePipelines", package: "AdaEngine"),
        .product(name: "AdaScene", package: "AdaEngine"), .product(name: "AdaSprite", package: "AdaEngine")]),
    .target(name: "AdaScriptAOTFixture", dependencies: [.product(name: "CGravity", package: "gravity-lang")],
        path: "Tests/AdaScriptAOTFixture", exclude: ''' + json.dumps(excluded) + ''', publicHeadersPath: "include"),
    .testTarget(name: "ShaderGraphValidationTests", dependencies: [
''' + dependencies + ''', "AdaShaderGraphBaker", "AdaScriptAOTFixture", .product(name: "GravityAOT", package: "gravity-lang")])
])
''')
print(destination)
