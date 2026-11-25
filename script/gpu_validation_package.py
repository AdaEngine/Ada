#!/usr/bin/env python3
"""Stage focused production test sources without building unrelated demo/editor targets."""
import argparse
import json
import os
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("destination", type=Path)
parser.add_argument("--include-sponza-demo", action="store_true", help="Build the Sponza demo and camera tests with the same renderer objects")
parser.add_argument("--examples-root", type=Path, default=os.environ.get("ADAEXAMPLES_PATH"), help="AdaExamples checkout for optional Sponza validation")
args = parser.parse_args()
if args.include_sponza_demo:
    if args.examples_root is None:
        parser.error("--include-sponza-demo requires --examples-root or ADAEXAMPLES_PATH pointing to AdaExamples")
    sponza_source = args.examples_root.resolve() / "Examples/Technical/Sponza"
    if not (sponza_source / "SponzaDemo.swift").is_file():
        parser.error("The examples checkout does not contain Examples/Technical/Sponza")
destination = args.destination.resolve()
sources = destination / "Tests/RenderingValidationTests"
sources.mkdir(parents=True, exist_ok=True)
if not args.include_sponza_demo:
    (sources / "SponzaCameraTests.swift").unlink(missing_ok=True)
pixel_perfect = os.environ.get("ADAENGINE_PIXEL_PERFECT_SAGA_SMOKE") == "1"
pixel_perfect_source = "Tests/AdaEngineTests/PixelPerfectMetalTests.swift"
if pixel_perfect:
    shutil.copy2(root / pixel_perfect_source, sources / Path(pixel_perfect_source).name)
else:
    (sources / Path(pixel_perfect_source).name).unlink(missing_ok=True)
for legacy_test in ("ShaderIncluderTests.swift", "ShaderCacheKeyTests.swift", "MetalVisibilityProcessorTests.swift"):
    (sources / legacy_test).unlink(missing_ok=True)
for relative in [
    "Tests/AdaRenderTests/WESLShaderModuleTests.swift",
    "Tests/AdaRenderTests/MeshBufferTests.swift",
    "Tests/AdaTextTests/TextShaderRenderingTests.swift",
    "Tests/AdaRenderTests/SAGAVulkanDeviceTests.swift",
    "Tests/AdaRenderTests/SAGAIndexedIndirectTests.swift",
    "Tests/AdaRenderTests/SAGAVisibilityProcessorTests.swift",
    "Tests/AdaRenderTests/SAGACommandCompletionTests.swift",
    "Tests/AdaRenderTests/SAGAMetalNativeSubmissionTests.swift",
    "Tests/AdaRenderTests/MetalResourceDeviceTests.swift",
    "Tests/AdaRenderTests/MetalFoveationTests.swift",
    "Tests/AdaRenderTests/TextureImportSettingsTests.swift",
    "Tests/AdaEngineTests/Foveated3DRenderingTests.swift",
    "Tests/AdaEngineTests/Render3DSkyboxDisplayTests.swift",
    "Tests/AdaEngineTests/WESLShadowPipelineTests.swift",
    "Tests/AdaEngineTests/WESLGradientPipelineTests.swift",
    "Tests/AdaEngineTests/WESLUIPipelineTests.swift",
    "Tests/AdaUITests/UIShapeGeometryTests.swift",
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
    "Tests/AdaRenderTests/DLSSSelectionTests.swift",
    "Tests/AdaRenderTests/DLSSStatusTests.swift",
    "Tests/AdaRenderTests/MeshletGeometryTests.swift",
    "Tests/AdaRenderTests/MeshletLODGeometryTests.swift",
    "Tests/AdaEngineTests/Render3DMeshletTests.swift",
    "Tests/AdaEngineTests/Render3DMeshletLODTests.swift",
    "Tests/AdaEngineTests/Render3DMeshletLODTemporalTests.swift",
    "Tests/AdaEngineTests/Render3DTerrainTextureTests.swift",
    "Tests/AdaEngineTests/Render3DTerrainMaterialTests.swift",
    "Tests/AdaEngineTests/Render3DTerrainMaterialFixture.swift",
    "Tests/AdaEngineTests/Render3DTerrainHeightBlendTests.swift",
    "Tests/AdaEngineTests/Render3DTerrainSurfacePaintTests.swift",
    "Tests/AdaEngineTests/Render3DTerrainLiveBrushTests.swift",
    "Tests/AdaEngineTests/Render3DTerrainUploadBudgetTests.swift",
    "Tests/AdaEngineTests/Render3DTerrainTracingFallbackTests.swift",
    "Tests/AdaEngineTests/Render3DLightingFoundationTests.swift",
    "Tests/AdaEngineTests/Render3DBakedLightingTests.swift",
    "Tests/AdaEngineTests/Render3DDynamicIrradianceTests.swift",
    "Tests/AdaEngineTests/Render3DPathTracingTests.swift",
    "Tests/AdaEngineTests/Render3DHardwarePathTracingTests.swift",
    "Tests/AdaEngineTests/Temporal3DTests.swift",
    "Tests/AdaEngineTests/Render3DSkinningBatchTests.swift",
    "Tests/AdaRenderTests/WindowFrameRequestsTests.swift",
    "Tests/AdaEngineTests/MaterialUploadReuseTests.swift",
    "Tests/AdaECSTests/OptionalResourceTests.swift",
    "Tests/AdaECSTests/ComponentChangeJournalTests.swift",
    "Tests/AdaTransformTests/AdaTransformTests.swift",
    # 3D post-processing and debug views render through the selected GPU backend and compare against references.
    "Tests/AdaEngineTests/GoldenFrameSupport.swift",
    "Tests/AdaEngineTests/WESLRenderProbe.swift",
    "Tests/AdaEngineTests/PluginLoadingTests.swift",
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
    "Tests/AdaEngineTests/Render3DDecalLifecycleTests.swift",
    "Tests/AdaEngineTests/Render3DDecalProjectionTests.swift",
    "Tests/AdaEngineTests/ColorCurves3DTests.swift",
    "Tests/AdaEngineTests/Render3DAutoExposureTests.swift",
    "Tests/AdaEngineTests/Render3DDepthOfFieldTests.swift",
    "Tests/AdaEngineTests/Render3DCameraEffectsTests.swift",
    "Tests/AdaEngineTests/Render3DParticleTests.swift",
    "Tests/AdaEngineTests/ParticleLighting3DTests.swift",
    "Tests/AdaEngineTests/LocalEnvironmentProbe3DTests.swift",
    "Tests/AdaEngineTests/Render3DHybridReflectionTests.swift",
    "Tests/AdaSceneTests/Decal3DPlacementTests.swift",
    "Tests/AdaSceneTests/Particle3DTests.swift",
    "Tests/AdaEngineTests/Render3DReflectionTests.swift",
    "Tests/AdaEngineTests/Render3DPerformanceBenchmarkTests.swift",
    "Tests/AdaEngineTests/Render3DTerrainInstanceBenchmarkTests.swift",
    "Tests/AdaEngineTests/MeshletBaselineFixtures.swift",
    "Tests/AdaEngineTests/Render3DMeshletBaselineTests.swift",
    "Tests/AdaEngineTests/SponzaBenchmarkSupport.swift",
    "Tests/AdaEngineTests/Render3DSponzaBenchmarkTests.swift",
    "Tests/AdaEngineTests/VisibleMesh3DListsEquivalenceTests.swift",
    "Tests/AdaEngineTests/Render3DMetricsReportTests.swift",
    "Tests/AdaEngineTests/GoldenBackendAgreementTests.swift",
    "Tests/AdaEngineTests/Render3DSagaNativeTests.swift",
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
# Meshlet and decal projection tests load garden fixtures through the production glTF loader.
garden_fixtures = root / "Tests/AdaEngineTests/Fixtures/SkeletalGardenAssets"
for name in ["Courtyard", "Bench", "Lantern", "Pedestal", "TwoBoneRibbon"]:
    fixture_destination = sources / "Fixtures/SkeletalGardenAssets"
    fixture_destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(garden_fixtures / (name + ".glb"), fixture_destination / (name + ".glb"))
# AdaAssets has no package product; AdaScene re-exports it.
modules = ["AdaAnimation", "AdaApp", "AdaCorePipelines", "AdaECS", "AdaRender", "AdaScene", "AdaSprite", "AdaText", "AdaTilemap", "AdaTransform", "AdaUtils", "Math"]
dependencies = ',\n'.join('.product(name: ' + json.dumps(module) + ', package: "AdaEngine")' for module in modules)
dependencies += ',\n.product(name: "AdaUI", package: "AdaEngine", condition: .when(platforms: [.windows]))'
if pixel_perfect:
    dependencies += ',\n.product(name: "AdaEngine", package: "AdaEngine", condition: .when(platforms: [.macOS]))'
extra_targets = ""
if args.include_sponza_demo:
    demo = destination / "Examples/Sponza"
    camera = destination / "Examples/SponzaCamera"
    demo.mkdir(parents=True, exist_ok=True)
    camera.mkdir(parents=True, exist_ok=True)
    for name in ["SponzaDemo.swift", "SponzaDemoProfiler.swift", "SponzaLighting.swift", "SponzaStutterProfiler.swift", "SponzaWarmup.swift"]:
        shutil.copy2(sponza_source / name, demo / name)
    shutil.copytree(sponza_source / "Assets", demo / "Assets", dirs_exist_ok=True)
    for source in (sponza_source / "Camera").glob("*.swift"):
        shutil.copy2(source, camera / source.name)
    shutil.copy2(sponza_source / "Tests/SponzaCameraTests.swift", sources / "SponzaCameraTests.swift")
    dependencies += ',\n"SponzaCamera"'
    extra_targets = ''', .target(name: "SponzaCamera", dependencies: [
        .product(name: "AdaTransform", package: "AdaEngine"), .product(name: "Math", package: "AdaEngine")], path: "Examples/SponzaCamera"),
    .executableTarget(name: "SponzaDemo", dependencies: ["SponzaCamera", .product(name: "AdaEngine", package: "AdaEngine"),
        .product(name: "Math", package: "AdaEngine")], path: "Examples/Sponza", resources: [.copy("Assets")])'''
test_settings = []
enabled_values = {"1", "true", "yes", "on"}
if not any(os.environ.get(setting, "").lower() in enabled_values for setting in ("ADAENGINE_HEADLESS", "ADAENGINE_WEB_EXPORT")):
    test_settings.append('.define("SAGA_NATIVE", .when(platforms: [.windows, .linux]))')
    if os.environ.get("ADAENGINE_ANDROID") != "1":
        test_settings.append('.define("SAGA_METAL_NATIVE_PASS", .when(platforms: [.macOS]))')
swift_settings = ", swiftSettings: [" + ", ".join(test_settings) + "]" if test_settings else ""
(destination / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "RenderingValidation", platforms: [.macOS(.v15)], dependencies: [
    .package(name: "AdaEngine", path: ''' + json.dumps(str(root)) + ''')
], targets: [.testTarget(name: "RenderingValidationTests", dependencies: [
''' + dependencies + '\n]' + swift_settings + ')' + extra_targets + '])\n')
print(destination)
