#if os(macOS) || os(Windows) || os(Linux)
import AdaAssets
import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    @Suite("Hybrid IBL and SSR")
    @MainActor
    struct HybridReflections {
        @Test(.enabled(if: GoldenFrame.activeBackend != nil))
        func screenHitsReplaceProbeAndMissesPreserveIt() async throws {
            let scene = try await DebugViews.makeScene()
            try #require(scene.device.supportsHybridReflections, "This GPU must support five HDR targets for the hybrid pixel test.")
            for entity in scene.app.main.getEntities() where entity.id != scene.camera.id && entity.id != scene.sun.id {
                scene.app.main.removeEntity(entity)
            }
            try scene.setSunIntensity(0)
            scene.camera.components[Transform.self] = Transform(position: [0, 1, -4])
            let diffuse = Texture2D(image: Image(width: 2, height: 1, color: .black))
            let specular = Texture2D(image: Image(width: 2, height: 2, color: Color(red: 0.15, green: 0.15, blue: 0.15)))
            let brdf = Texture2D(image: Image(width: 2, height: 2, color: Color(red: 1, green: 0, blue: 0)))
            let maps = AssetHandle(ImageBasedLighting3D(irradiance: diffuse, specular: specular, brdf: brdf, specularLevels: 2))
            try scene.configure {
                $0.imageBasedLighting = ImageBasedLightingSettings(asset: maps)
                $0.localEnvironmentProbe = LocalEnvironmentProbe3D(capturePosition: [0, 1, 0], minimum: [-10, -1, -10], maximum: [10, 5, 10])
                $0.skybox.isEnabled = false
                $0.ambientOcclusion.isEnabled = false
                $0.screenSpaceReflection = ScreenSpaceReflection(isEnabled: false, maxDistance: 20, stride: 0.2, thickness: 0.3, maxSteps: 64, intensity: 1)
            }
            let mirror = PBRMaterial()
            mirror.baseColorFactor = [1, 1, 1, 1]
            mirror.metallicFactor = 1
            mirror.roughnessFactor = 0.04
            scene.app.main.spawn("Mirror floor") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [16, 0.1, 16], renderDevice: scene.device), materials: [mirror])
                Transform(position: [0, -0.05, 1])
            }
            let red = PBRMaterial()
            red.baseColorFactor = [0, 0, 0, 1]
            red.metallicFactor = 0
            red.emissiveFactor = [1, 0, 0]
            red.emissiveStrength = 4
            scene.app.main.spawn("Red reflection source") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [2, 2, 0.5], renderDevice: scene.device), materials: [red])
                Transform(position: [0, 1, 2])
            }
            let baseline = try await scene.render(.none)
            try scene.configure { $0.screenSpaceReflection.isEnabled = true; $0.screenSpaceReflection.maxDistance = 0 }
            let miss = try await scene.render(.none)
            #expect(GoldenFrame.compare(miss, baseline, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance),
                    "A miss must keep the baked IBL exactly; it must not add a second specular lobe.")
            try scene.configure { $0.screenSpaceReflection.maxDistance = 20 }
            let reflected = try await scene.render(.none)
            var redStep: Float = 0
            for y in 260..<470 {
                for x in 240..<400 {
                    let before = baseline.getPixel(x: x, y: y), after = reflected.getPixel(x: x, y: y)
                    redStep = max(redStep, (after.red-after.green) - (before.red-before.green))
                }
            }
            #expect(redStep > 0.1, "SSR must remain active with an IBL capture and reflect the red emitter: \(redStep).")
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try baseline.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("hybrid-probe-only.png"))
            try reflected.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("hybrid-probe-ssr.png"))
        }
    }
}
#endif
