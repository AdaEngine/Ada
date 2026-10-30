#if os(macOS) || os(Windows) || os(Linux)
import AdaAssets
@testable import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    @Suite("Lighting foundation")
    @MainActor
    struct LightingFoundation {
        @Test(.enabled(if: GoldenFrame.activeBackend != nil))
        func localFogWorksWithoutSunAndFollowsTheSpotlight() async throws {
            let scene = try await DebugViews.makeScene()
            try scene.setSunIntensity(0)
            for entity in scene.app.main.getEntities() where entity.id != scene.camera.id && entity.id != scene.sun.id {
                scene.app.main.removeEntity(entity)
            }
            try scene.configure {
                $0.fog = .init(isEnabled: true, color: .black, density: 0, skyInfluence: 1,
                    volumetric: .init(isEnabled: true, intensity: 2, anisotropy: 0, steps: 48, maxDistance: 8))
                $0.fog.localVolumes = [.init(minimum: [-3,-2,-2], maximum: [3,4,4], density: 0.3)]
            }
            let lamp = scene.app.main.spawn("Fog flashlight") {
                SpotLightComponent(radiance: [1,0.05,0.01], intensity: 20, castShadows: true,
                    range: 8, innerConeAngle: 12, outerConeAngle: 25)
                Transform(position: [-0.5,0.5,-2.5])
            }
            let forward = try await scene.render(.none, frames: 4)
            lamp.components[Transform.self] = Transform(rotation: Quat.euler([0,1.3,0]), position: [-0.5,0.5,-2.5])
            let turned = try await scene.render(.none, frames: 4)
            var delta: Float = 0
            for y in 100..<380 { for x in 100..<540 {
                delta = max(delta, forward.getPixel(x:x,y:y).red-turned.getPixel(x:x,y:y).red)
            } }
            #expect(delta > 0.04, "The cone must follow the real spotlight even with zero global density and no sun.")
            lamp.components[Transform.self] = Transform(position: [-0.5,0.5,-2.5])
            let blockerMaterial = PBRMaterial()
            blockerMaterial.baseColorFactor = [0,0,0,1]; blockerMaterial.metallicFactor = 0; blockerMaterial.roughnessFactor = 1
            let blocker = scene.app.main.spawn("Fog shadow blocker") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [0.45,1.3,0.15], renderDevice: scene.device), materials: [blockerMaterial])
                Transform(position: [-0.5,0.5,-1.1])
            }
            let shadowed = try await scene.render(.none, frames: 3)
            var mesh = try #require(blocker.components[Mesh3DComponent.self])
            mesh.castShadows = false; blocker.components[Mesh3DComponent.self] = mesh
            let unshadowed = try await scene.render(.none, frames: 3)
            var shadowDelta: Float = 0
            for y in 80..<400 { for x in 80..<560 {
                shadowDelta = max(shadowDelta, unshadowed.getPixel(x:x,y:y).red-shadowed.getPixel(x:x,y:y).red)
            } }
            #expect(shadowDelta > 0.01, "The local shadow atlas must occlude scattering behind the blocker: \(shadowDelta)")
            scene.app.main.removeEntity(blocker)
            try scene.configure { $0.fog.localVolumes = [.init(minimum: [30,-2,-2], maximum: [36,4,4], density: 0.3)] }
            let outside = try await scene.render(.none)
            try scene.configure { $0.fog.isEnabled = false }
            let disabled = try await scene.render(.none)
            #expect(GoldenFrame.compare(outside, disabled, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
            try forward.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("local-fog-spotlight.png"))
        }

        @Test(.enabled(if: GoldenFrame.activeBackend != nil))
        func portableTemporalReconstructsMotionAndResetsWithoutVendorSDK() async throws {
            let scene = try await DebugViews.makeScene(temporalRenderScale: 1)
            var camera = try #require(scene.camera.components[Camera.self])
            camera.temporalUpscaling = .init(renderScale: 1, method: .portable)
            scene.camera.components[Camera.self] = camera
            _ = try await scene.render(.none, frames: 12)
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld))
            let statistics = try #require(world.getResource(Render3DTemporalStatistics.self))
            let key = "\(scene.camera.id)"
            #expect(try #require(statistics.snapshots[key]).encodedFrames >= 12)
            #expect(try #require(statistics.snapshots[key]).fallbackFrames == 0)
            scene.camera.components[Transform.self] = Transform(position: [0.15, 0.5, -3.4])
            let moved = try await scene.render(.none, frames: 8)
            camera.temporalUpscaling = nil; scene.camera.components[Camera.self] = camera
            let native = try await scene.render(.none, frames: 4)
            var difference: Float = 0
            for y in stride(from: 0, to: 480, by: 4) { for x in stride(from: 0, to: 640, by: 4) {
                let a = moved.getPixel(x:x,y:y), b = native.getPixel(x:x,y:y)
                difference += abs(a.red-b.red)+abs(a.green-b.green)+abs(a.blue-b.blue)
            } }
            #expect(difference / (160*120*3) < 0.04)
            camera.temporalUpscaling = .init(renderScale: 0.67, method: .portable)
            scene.camera.components[Camera.self] = camera
            _ = try await scene.render(.none, frames: 6)
            #expect(try #require(statistics.snapshots[key]).fallbackFrames == 0)
            #expect(try #require(statistics.snapshots[key]).inputWidth < 640)
            let resets = try #require(statistics.snapshots[key]).historyResets
            scene.camera.components[Transform.self] = Transform(position: [8,0.5,-3.4])
            _ = try await scene.render(.none, frames: 2)
            #expect(try #require(statistics.snapshots[key]).historyResets > resets)
            try moved.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("taa-moving.png"))
        }

        @Test(.enabled(if: GoldenFrame.activeBackend != nil))
        func contactAndPCSSShadowsRenderAndDisableCleanly() async throws {
            let scene = try await DebugViews.makeScene()
            try scene.configure { $0.ambientOcclusion.isEnabled = false; $0.shadows.resolution = 128 }
            let baseline = try await scene.render(.none)
            try scene.configure {
                $0.contactShadows = .init(isEnabled: true, rayLength: 0.6, thickness: 0.12, steps: 24)
            }
            let contact = try await scene.render(.none, frames: 3)
            var contactDelta: Float = 0
            for y in 200..<460 { for x in 80..<560 {
                contactDelta = max(contactDelta, baseline.getPixel(x:x,y:y).red-contact.getPixel(x:x,y:y).red)
            } }
            #expect(contactDelta > 0.005, "Contact rays must shadow direct light beyond the coarse map: \(contactDelta)")
            try scene.configure { $0.shadows.filter = .pcss; $0.shadows.lightAngularRadius = 3 }
            let changed = try await scene.render(.none, frames: 4)
            var delta: Float = 0
            for y in 200..<460 { for x in 80..<560 {
                delta = max(delta, abs(changed.getPixel(x:x,y:y).red-baseline.getPixel(x:x,y:y).red))
            } }
            #expect(delta > 0.02, "Source visibility and variable penumbra must affect pixels.")
            try scene.configure { $0.contactShadows.isEnabled = false; $0.shadows.filter = .pcf }
            let disabled = try await scene.render(.none)
            #expect(GoldenFrame.compare(disabled, baseline, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld))
            #expect(world.getResource(SurfaceLighting3DViews.self)?.textures.isEmpty == true)
            try changed.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("pcss-contact.png"))
        }

        @Test(.enabled(if: GoldenFrame.activeBackend != nil))
        func diffuseTransportUsesVisibleRadianceAndDisablingRestoresTheFrame() async throws {
            let scene = try await DebugViews.makeScene()
            try #require(scene.device.supportsLightingSurfaceBuffer)
            for entity in scene.app.main.getEntities() where entity.id != scene.camera.id && entity.id != scene.sun.id {
                scene.app.main.removeEntity(entity)
            }
            try scene.setSunIntensity(0)
            scene.camera.components[Transform.self] = Transform(position: [0, 1.2, -3.5])
            try scene.configure {
                $0.skybox.isEnabled = false; $0.imageBasedLighting = nil
                $0.ambientOcclusion.isEnabled = false; $0.screenSpaceReflection.isEnabled = false
                $0.screenSpaceGI = .init(isEnabled: false, maxDistance: 5, rayCount: 16, stepCount: 32)
            }
            let floor = PBRMaterial()
            floor.baseColorFactor = [0.8,0.8,0.8,1]; floor.roughnessFactor = 1; floor.metallicFactor = 0
            scene.app.main.spawn("Diffuse receiver") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [8,0.1,10], renderDevice: scene.device), materials: [floor])
                Transform(position: [0,-0.05,2])
            }
            let red = PBRMaterial()
            red.baseColorFactor = [0,0,0,1]; red.emissiveFactor = [1,0,0]; red.emissiveStrength = 4
            let source = scene.app.main.spawn("Visible red radiator") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [2,2,0.1], renderDevice: scene.device), materials: [red])
                Transform(position: [0,1,2])
            }
            let baseline = try await scene.render(.none)
            try scene.configure { $0.screenSpaceGI.isEnabled = true }
            let bounced = try await scene.render(.none, frames: 6)
            var redBounce: Float = 0
            for y in 310..<460 { for x in 160..<480 {
                let a = baseline.getPixel(x: x, y: y), b = bounced.getPixel(x: x, y: y)
                redBounce = max(redBounce, (b.red-a.red) - (b.green-a.green))
            } }
            #expect(redBounce > 0.03, "Visible red radiance must illuminate the diffuse floor: \(redBounce)")
            red.emissiveStrength = 0
            let dark = try await scene.render(.none)
            var remaining: Float = 0
            for y in 310..<460 { for x in 160..<480 { remaining = max(remaining, dark.getPixel(x: x,y: y).red-baseline.getPixel(x: x,y: y).red) } }
            #expect(remaining < redBounce * 0.5, "Changing the source must change GI without an offline rebake.")
            red.emissiveStrength = 4
            source.components[Transform.self] = Transform(position: [0,1,2])
            try scene.configure { $0.screenSpaceGI.isEnabled = false }
            let disabled = try await scene.render(.none)
            #expect(GoldenFrame.compare(disabled, baseline, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld))
            #expect(world.getResource(ScreenSpaceGI3DViews.self)?.textures.isEmpty == true)
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try baseline.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("ssgi-off.png"))
            try bounced.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("ssgi-on.png"))
        }
    }
}
#endif

@Suite struct LightingFoundationSettingsTests {
    @Test func olderSettingsDecodeDisabledAndUnsafeValuesAreBounded() throws {
        let settings = try JSONDecoder().decode(ScreenSpaceGI3D.self, from: Data("{}".utf8))
        #expect(!settings.isEnabled)
        let bounded = ScreenSpaceGI3D(isEnabled: true, intensity: .nan, maxDistance: -.infinity,
            thickness: -5, bias: .infinity, rayCount: 999, stepCount: -8).sanitized
        #expect(bounded.intensity == 1 && bounded.maxDistance == 5)
        #expect(bounded.rayCount == 16 && bounded.stepCount == 4 && bounded.thickness > 0)
        let environment = try JSONDecoder().decode(Environment3D.self, from: Data("{}".utf8))
        #expect(!environment.screenSpaceGI.isEnabled)
        #expect(!environment.contactShadows.isEnabled && environment.shadows.filter == .pcf)
        #expect(environment.fog.localVolumes.isEmpty)
        let temporal = try JSONDecoder().decode(TemporalUpscalingSettings.self, from: Data("{\"renderScale\":1,\"resetGeneration\":0}".utf8))
        #expect(temporal.method == .automatic)
    }
}
