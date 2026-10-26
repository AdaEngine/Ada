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
for relative in [
    "Tests/AdaUtilsTests/TintToolchainTests.swift",
    "Tests/AdaRenderTests/TintShaderCompilerTests.swift",
    "Tests/AdaRenderTests/WGSLReflectionTests.swift",
    "Tests/AdaRenderTests/ShaderGraphTests.swift",
    "Tests/AdaRenderTests/ShaderGraphProgramTests.swift",
    "Tests/AdaRenderTests/ShaderGraphMaterialTests.swift",
    "Tests/AdaRenderTests/ShaderGraphEffectTests.swift",
    "Tests/AdaRenderTests/ShaderGraphArchiveTests.swift",
    "Tests/AdaEngineTests/SpriteMetalRenderingTests.swift",
    "Tests/AdaRenderTests/BoundedResourceCacheTests.swift",
    "Tests/AdaRenderTests/RenderGraphDiagnosticsTests.swift",
    "Tests/AdaRenderTests/RenderUpscalingTests.swift",
    "Tests/AdaEngineTests/Render3DFSRTests.swift",
    "Tests/AdaRenderTests/WindowFrameRequestsTests.swift",
    "Tests/AdaRenderTests/WGPUBindingStateTests.swift",
    "Tests/AdaRenderTests/WGPUVisibilityProcessorTests.swift",
    "Tests/AdaEngineTests/MaterialUploadReuseTests.swift",
    "Tests/AdaECSTests/OptionalResourceTests.swift",
    "Tests/AdaRenderTests/ShaderIncluderTests.swift",
    "Tests/AdaRenderTests/ShaderCacheKeyTests.swift",
    # 3D post-processing and debug views render through the selected GPU backend and compare against references.
    "Tests/AdaEngineTests/GoldenFrameSupport.swift",
    "Tests/AdaEngineTests/PluginLoadingTests.swift",
    "Tests/AdaEngineTests/WGPUVisibilitySceneTests.swift",
    "Tests/AdaEngineTests/Render3DDebugViewTests.swift",
    "Tests/AdaEngineTests/Render3DReflectedFacingTests.swift",
    "Tests/AdaEngineTests/Render3DShaderGraphTests.swift",
    "Tests/AdaEngineTests/Render3DMaterialExtensionTests.swift",
    "Tests/AdaEngineTests/Render3DFogTests.swift",
    "Tests/AdaEngineTests/Render3DPostProcessTests.swift",
    "Tests/AdaEngineTests/Render3DColorGradingTests.swift",
    "Tests/AdaEngineTests/Render3DAutoExposureTests.swift",
    "Tests/AdaEngineTests/Render3DDepthOfFieldTests.swift",
    "Tests/AdaEngineTests/Render3DReflectionTests.swift",
    "Tests/AdaEngineTests/Render3DPerformanceBenchmarkTests.swift",
    "Tests/AdaEngineTests/VisibleMesh3DListsEquivalenceTests.swift",
    "Tests/AdaEngineTests/Render3DMetricsReportTests.swift",
    "Tests/AdaEngineTests/GoldenBackendAgreementTests.swift",
]:
    source = root / relative
    shutil.copy2(source, sources / source.name)
# Golden frames are read from next to the staged test sources unless ADAENGINE_GOLDEN_REFERENCES points elsewhere.
golden_frames = root / "Tests/AdaEngineTests/GoldenFrames"
if golden_frames.is_dir():
    shutil.copytree(golden_frames, sources / "GoldenFrames", dirs_exist_ok=True)
# AdaAssets has no package product; AdaScene re-exports it.
modules = ["AdaApp", "AdaCorePipelines", "AdaECS", "AdaRender", "AdaScene", "AdaSprite", "AdaTilemap", "AdaTransform", "AdaUtils", "Math"]
dependencies = ',\n'.join('.product(name: ' + json.dumps(module) + ', package: "AdaEngine")' for module in modules)
(destination / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "RenderingValidation", platforms: [.macOS(.v15)], dependencies: [
    .package(name: "AdaEngine", path: ''' + json.dumps(str(root)) + ''')
], targets: [.testTarget(name: "RenderingValidationTests", dependencies: [
''' + dependencies + '\n])])\n')
print(destination)
