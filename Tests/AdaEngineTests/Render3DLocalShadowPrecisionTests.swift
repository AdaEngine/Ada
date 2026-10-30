#if os(macOS) || os(Windows) || os(Linux)
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

extension Render3DGPUTests {
    @Suite("Local shadow depth precision")
    @MainActor
    struct LocalShadowPrecision {
        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func aThinCasterNearTheLightRangeKeepsItsShadow() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            for entity in scene.app.main.getEntities() where entity.id != scene.camera.id && entity.id != scene.sun.id {
                scene.app.main.removeEntity(entity)
            }
            try scene.setSunIntensity(0)
            try scene.configure {
                $0.imageBasedLighting = nil
                $0.skybox.isEnabled = false
                $0.screenSpaceReflection.isEnabled = false
                $0.ambientOcclusion.isEnabled = false
                $0.contactShadows.isEnabled = false
                $0.screenSpaceGI.isEnabled = false
                $0.postProcess.bloom.isEnabled = false
                $0.postProcess.autoExposure.isEnabled = false
                $0.postProcess.exposureEV = 0
                $0.localShadows = .init(isEnabled: true, maximumLights: 1, reusesStaticFaces: false)
            }
            var camera = try #require(scene.camera.components[Camera.self])
            camera.fieldOfViewDegrees = 50
            // A missing receiver must fail the lit-control check instead of
            // accidentally accepting the helper scene's bright sky color.
            camera.backgroundColor = .black
            scene.camera.components[Camera.self] = camera
            // See the receiver's shadow from the side, without the caster itself
            // covering it. The light remains on the receiver's normal axis.
            scene.camera.components[Transform.self] = Transform(
                rotation: Quat(axis: [0, 1, 0], angle: -0.8491415), position: [1.5, 1.2, 2.5])

            let receiver = PBRMaterial()
            receiver.baseColorFactor = [0.8, 0.8, 0.8, 1]
            receiver.metallicFactor = 0
            receiver.roughnessFactor = 1
            scene.app.main.spawn("Shadow precision receiver") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [6, 3, 0.1], renderDevice: scene.device), materials: [receiver])
                // Its front face is 3.82 m along the selected point-light face.
                Transform(position: [0, 1.2, 3.87])
            }
            let blockerMaterial = PBRMaterial()
            blockerMaterial.baseColorFactor = [0.2, 0.2, 0.2, 1]
            blockerMaterial.metallicFactor = 0
            blockerMaterial.roughnessFactor = 1
            let blocker = scene.app.main.spawn("Thin nearby shadow caster") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [0.06, 1.4, 0.02], renderDevice: scene.device),
                    materials: [blockerMaterial], castShadows: false, receiveShadows: true)
                Transform(position: [0, 1.2, 3.79])
            }
            scene.app.main.spawn("Precision point light") {
                PointLightComponent(radiance: [1, 1, 1], intensity: 9, castShadows: true, range: 5.2,
                    shadowBias: 0.000015, shadowSlopeBias: 0)
                Transform(position: [0, 1.2, 0])
            }

            // Near .05 / far 5.2: the caster at 3.78 m has depth .9963528,
            // which rounds UP to .9965820 in half. The receiver at 3.82 m
            // has depth .9964927, so an FP16 atlas incorrectly puts it in
            // front of that caster. R32 keeps the physical ordering.
            let unshadowed = try await scene.render(.none, frames: 6)
            let control = unshadowed.getPixel(x: 321, y: 240)
            try #require(control.red > 0.12, "The receiver must be lit and visible in the control frame.")
            var mesh = try #require(blocker.components[Mesh3DComponent.self])
            mesh.castShadows = true
            blocker.components[Mesh3DComponent.self] = mesh
            let shadowed = try await scene.render(.none, frames: 6)
            var maximumDrop: Float = 0
            var changedPixels = 0
            for y in 150..<330 {
                for x in 315..<335 {
                    let drop = unshadowed.getPixel(x: x, y: y).red - shadowed.getPixel(x: x, y: y).red
                    maximumDrop = max(maximumDrop, drop)
                    if drop > 0.05 { changedPixels += 1 }
                }
            }
            #expect(maximumDrop > 0.1, "A nearby thin caster must cast a real shadow: largest drop \(maximumDrop).")
            #expect(changedPixels > 30, "The shadow must cover a receiver patch, not a single noisy pixel: \(changedPixels).")

            mesh.castShadows = false
            blocker.components[Mesh3DComponent.self] = mesh
            let restored = try await scene.render(.none, frames: 4)
            #expect(GoldenFrame.compare(unshadowed, restored, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance),
                "Removing only shadow casting must restore the lit control image.")
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try unshadowed.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("local-shadow-precision-control.png"))
            try shadowed.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("local-shadow-precision-shadowed.png"))
            try JSONEncoder().encode(["maximumDrop": maximumDrop, "changedPixels": Float(changedPixels)])
                .write(to: GoldenFrame.outputDirectory.appendingPathComponent("local-shadow-precision.json"))
        }
    }
}
#endif
