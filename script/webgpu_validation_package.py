#!/usr/bin/env python3
"""Stage focused production test sources without building unrelated demo/editor targets."""
import argparse
import json
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("destination", type=Path)
parser.add_argument("--include-sponza-demo", action="store_true", help="Build the Sponza demo and camera tests with the same renderer objects")
args = parser.parse_args()
destination = args.destination.resolve()
sources = destination / "Tests/RenderingValidationTests"
sources.mkdir(parents=True, exist_ok=True)
if not args.include_sponza_demo:
    (sources / "SponzaCameraTests.swift").unlink(missing_ok=True)
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
    "Tests/AdaRenderTests/MeshletGeometryTests.swift",
    "Tests/AdaRenderTests/MeshletLODGeometryTests.swift",
    "Tests/AdaEngineTests/Render3DMeshletTests.swift",
    "Tests/AdaEngineTests/Render3DMeshletLODTests.swift",
    "Tests/AdaEngineTests/Render3DMeshletLODTemporalTests.swift",
    "Tests/AdaEngineTests/Render3DFSRTests.swift",
    "Tests/AdaEngineTests/Render3DDLSSTests.swift",
    "Tests/AdaEngineTests/Render3DLightingFoundationTests.swift",
    "Tests/AdaEngineTests/Render3DBakedLightingTests.swift",
    "Tests/AdaEngineTests/Render3DDynamicIrradianceTests.swift",
    "Tests/AdaEngineTests/Render3DPathTracingTests.swift",
    "Tests/AdaEngineTests/Temporal3DTests.swift",
    "Tests/AdaEngineTests/Render3DSkinningBatchTests.swift",
    "Tests/AdaRenderTests/WindowFrameRequestsTests.swift",
    "Tests/AdaRenderTests/WGPUBindingStateTests.swift",
    "Tests/AdaRenderTests/WGPUCommandCompletionTests.swift",
    "Tests/AdaRenderTests/WGPUVisibilityProcessorTests.swift",
    "Tests/AdaEngineTests/MaterialUploadReuseTests.swift",
    "Tests/AdaECSTests/OptionalResourceTests.swift",
    "Tests/AdaTransformTests/AdaTransformTests.swift",
    "Tests/AdaRenderTests/ShaderIncluderTests.swift",
    "Tests/AdaRenderTests/ShaderCacheKeyTests.swift",
    # 3D post-processing and debug views render through the selected GPU backend and compare against references.
    "Tests/AdaEngineTests/GoldenFrameSupport.swift",
    "Tests/AdaEngineTests/PluginLoadingTests.swift",
    "Tests/AdaEngineTests/WGPUVisibilitySceneTests.swift",
    "Tests/AdaEngineTests/Render3DDebugViewTests.swift",
    "Tests/AdaEngineTests/Render3DShadowFilteringTests.swift",
    "Tests/AdaEngineTests/Render3DLocalShadowPrecisionTests.swift",
    "Tests/AdaEngineTests/Render3DShadowCacheLifetimeTests.swift",
    "Tests/AdaEngineTests/Render3DDisplayDitherTests.swift",
    "Tests/AdaEngineTests/Render3DVolumetricQualityTests.swift",
    "Tests/AdaEngineTests/Render3DDistanceFieldTests.swift",
    "Tests/AdaEngineTests/Render3DReflectedFacingTests.swift",
    "Tests/AdaEngineTests/Render3DShaderGraphTests.swift",
    "Tests/AdaEngineTests/Render3DMaterialExtensionTests.swift",
    "Tests/AdaEngineTests/Render3DFogTests.swift",
    "Tests/AdaEngineTests/Render3DPostProcessTests.swift",
    "Tests/AdaEngineTests/Render3DColorGradingTests.swift",
    "Tests/AdaEngineTests/ColorCurves3DTests.swift",
    "Tests/AdaEngineTests/Render3DAutoExposureTests.swift",
    "Tests/AdaEngineTests/Render3DDepthOfFieldTests.swift",
    "Tests/AdaEngineTests/Render3DCameraEffectsTests.swift",
    "Tests/AdaEngineTests/Render3DParticleTests.swift",
    "Tests/AdaEngineTests/ParticleLighting3DTests.swift",
    "Tests/AdaEngineTests/LocalEnvironmentProbe3DTests.swift",
    "Tests/AdaEngineTests/Render3DHybridReflectionTests.swift",
    "Tests/AdaSceneTests/Particle3DTests.swift",
    "Tests/AdaEngineTests/Render3DReflectionTests.swift",
    "Tests/AdaEngineTests/Render3DPerformanceBenchmarkTests.swift",
    "Tests/AdaEngineTests/MeshletBaselineFixtures.swift",
    "Tests/AdaEngineTests/Render3DMeshletBaselineTests.swift",
    "Tests/AdaEngineTests/SponzaBenchmarkSupport.swift",
    "Tests/AdaEngineTests/Render3DSponzaBenchmarkTests.swift",
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
# Source-relative fresh compiler tests resolve this path from the staged package.
shutil.copytree(
    root / "Sources/AdaCorePipelines/Assets/Shaders",
    destination / "Sources/AdaCorePipelines/Assets/Shaders",
    dirs_exist_ok=True,
)
# Meshlet P0 uses original static garden props through the production glTF loader.
garden_fixtures = root / "Tests/AdaEngineTests/Fixtures/SkeletalGardenAssets"
for name in ["Courtyard", "Bench", "Lantern", "Pedestal"]:
    fixture_destination = sources / "Fixtures/SkeletalGardenAssets"
    fixture_destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(garden_fixtures / (name + ".glb"), fixture_destination / (name + ".glb"))
# AdaAssets has no package product; AdaScene re-exports it.
modules = ["AdaAnimation", "AdaApp", "AdaCorePipelines", "AdaECS", "AdaRender", "AdaScene", "AdaSprite", "AdaTilemap", "AdaTransform", "AdaUtils", "Math"]
dependencies = ',\n'.join('.product(name: ' + json.dumps(module) + ', package: "AdaEngine")' for module in modules)
extra_targets = ""
if args.include_sponza_demo:
    demo = destination / "Demos/Sponza"
    camera = destination / "Demos/SponzaCamera"
    demo.mkdir(parents=True, exist_ok=True)
    camera.mkdir(parents=True, exist_ok=True)
    for name in ["SponzaDemo.swift", "SponzaDemoProfiler.swift", "SponzaLighting.swift", "SponzaStutterProfiler.swift", "SponzaWarmup.swift"]:
        shutil.copy2(root / "Demos/Sponza" / name, demo / name)
    for source in (root / "Demos/Sponza/Camera").glob("*.swift"):
        shutil.copy2(source, camera / source.name)
    shutil.copy2(root / "Demos/Sponza/Tests/SponzaCameraTests.swift", sources / "SponzaCameraTests.swift")
    dependencies += ',\n"SponzaCamera"'
    extra_targets = ''', .target(name: "SponzaCamera", dependencies: [
        .product(name: "AdaTransform", package: "AdaEngine"), .product(name: "Math", package: "AdaEngine")], path: "Demos/SponzaCamera"),
    .executableTarget(name: "SponzaDemo", dependencies: ["SponzaCamera", .product(name: "AdaEngine", package: "AdaEngine"),
        .product(name: "Math", package: "AdaEngine")], path: "Demos/Sponza")'''
(destination / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "RenderingValidation", platforms: [.macOS(.v15)], dependencies: [
    .package(name: "AdaEngine", path: ''' + json.dumps(str(root)) + ''')
], targets: [.testTarget(name: "RenderingValidationTests", dependencies: [
''' + dependencies + '\n])' + extra_targets + '])\n')
print(destination)
