#if os(macOS) || os(Windows) || os(Linux)
import AdaECS
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import AdaTransform
import Math
import Testing
@testable import AdaCorePipelines

extension Render3DGPUTests {
    @Suite("3D soft particles on GPU") @MainActor
    struct Particles {
        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func layeredSmokeRespondsToLocalLightAndItsOpaqueOccluders() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            try scene.setSunIntensity(0)
            scene.camera.components[Camera.self]?.fieldOfViewDegrees = 60
            var settings = ParticleEmitter3D()
            settings.isEmitting = false; settings.burstCount = 1; settings.particleStyle = 3
            settings.initialVelocity = .zero; settings.velocityVariation = .zero
            settings.acceleration = .zero; settings.wind = .zero; settings.turbulence = 0
            settings.spawnRadius = 0; settings.initialSize = 0.8; settings.expansionRate = 0
            settings.opacity = 1; settings.color = [0.56, 0.57, 0.59]
            settings.lifetime = 10; settings.lifetimeVariation = 0
            var simulation = ParticleSimulation3D(seed: 1)
            let source = Transform3D(translation: [0, 1, -1.6])
            simulation.emitBurst(settings: settings, transform: source)
            simulation.advance(by: 0.2, settings: settings, transform: source)
            settings.simulation = simulation; settings.isPaused = true
            let emitter = scene.app.main.spawn { Transform(); settings }
            // This light reaches the cloud above the sphere row; the sampled region has only sky behind it.
            let light = scene.app.main.spawn {
                PointLightComponent(intensity: 0, castShadows: false, range: 1.1)
                Transform(position: [-0.7, 1, -1.6])
            }
            let blocker = PBRMaterial()
            blocker.baseColorFactor = [0.02, 0.02, 0.02, 1]
            scene.app.main.spawn {
                Transform(position: [-0.35, 1, -1.6])
                Mesh3DComponent(mesh: Mesh.generateCube(size: [0.05, 0.8, 0.9], renderDevice: scene.device), materials: [blocker])
            }
            emitter.components[Visibility.self] = .hidden
            let background = try await scene.render(.none)
            emitter.components[Visibility.self] = .visible
            let dark = try await scene.render(.none)
            // A cloud over an empty GBuffer must survive sky compositing. Derive its pixel from the
            // actual camera rather than assuming a fixed projection or render-target orientation.
            let camera = try #require(scene.camera.components[Camera.self])
            let viewCenter = camera.viewMatrix * Vector4(0, 1, -1.6, 1)
            let clipCenter = camera.computedData.projectionMatrix * viewCenter
            let centerX: Float = (clipCenter.x / clipCenter.w * 0.5 + 0.5) * Float(dark.width)
            let centerY: Float = (0.5 - clipCenter.y / clipCenter.w * 0.5) * Float(dark.height)
            var skyCoverage: Float = 0
            for y in (Int(centerY) - 3)...(Int(centerY) + 3) { for x in (Int(centerX) - 3)...(Int(centerX) + 3) {
                skyCoverage += background.getPixel(x: x, y: y).red - dark.getPixel(x: x, y: y).red
            } }
            #expect(skyCoverage > 0.05 * 49, "Smoke in front of the sky must not be overwritten when the opaque GBuffer is empty.")
            light.components[PointLightComponent.self]?.intensity = 6
            let lit = try await scene.render(.none)
            #expect(GoldenFrame.compare(dark, lit, tolerance: GoldenFrame.activeTolerance).differingPixels > 500)
            light.components[PointLightComponent.self]?.intensity = 0
            let recovered = try await scene.render(.none)
            #expect(GoldenFrame.compare(dark, recovered, tolerance: GoldenFrame.activeTolerance).differingPixels == 0)
            light.components[PointLightComponent.self]?.intensity = 6
            // Use exactly the same blocker in both lighting states. Background controls exclude any
            // pixels where the blocker itself, or an opaque receiver, changes the result.
            emitter.components[Visibility.self] = .hidden
            let unshadowedBackground = try await scene.render(.none)
            light.components[PointLightComponent.self]?.castShadows = true
            let shadowedBackground = try await scene.render(.none)
            emitter.components[Visibility.self] = .visible
            let shadowed = try await scene.render(.none)
            var bright: Float = 0
            var occluded: Float = 0
            var smokePixels = 0
            for y in 0..<lit.height { for x in 0..<lit.width {
                let unshadowed = lit.getPixel(x: x, y: y).red
                let unlit = dark.getPixel(x: x, y: y).red
                let bare = unshadowedBackground.getPixel(x: x, y: y).red
                let bareShadowed = shadowedBackground.getPixel(x: x, y: y).red
                guard unshadowed > unlit + 0.04, abs(unshadowed - bare) > 0.01, abs(bare - bareShadowed) <= 1 / 255 else { continue }
                smokePixels += 1
                bright += unshadowed
                occluded += shadowed.getPixel(x: x, y: y).red
            } }
            #expect(smokePixels > 100, "The control must contain a visible locally illuminated cloud, excluding directly occluded geometry.")
            #expect(bright > occluded + 0.025 * Float(smokePixels), "The cloud must receive the current local shadow atlas, not shine through the blocker.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func smokeIsVisibleInFrontAndOccludedBehindOpaqueGeometry() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let baseline = try await scene.render(.none)
            var settings = ParticleEmitter3D()
            settings.emissionRate = 0; settings.burstCount = 1; settings.loops = false
            settings.initialVelocity = .zero; settings.velocityVariation = .zero
            settings.acceleration = .zero; settings.wind = .zero; settings.turbulence = 0
            settings.spawnRadius = 0; settings.initialSize = 0.5; settings.expansionRate = 0
            settings.opacity = 1; settings.color = [0.02, 0.02, 0.02]
            settings.lifetime = 10; settings.lifetimeVariation = 0
            let emitter = scene.app.main.spawn { Transform(); settings }
            func place(_ position: Vector3) {
                var simulation = ParticleSimulation3D(seed: 1)
                simulation.advance(by: 0.2, settings: settings,
                    transform: Transform3D(translation: position, rotation: .identity, scale: .one))
                var paused = settings
                paused.simulation = simulation
                paused.isPaused = true
                emitter.components[ParticleEmitter3D.self] = paused
            }
            place([-0.55, 0.5, 0.8])
            let behind = try await scene.render(.none)
            #expect(GoldenFrame.compare(baseline, behind, tolerance: GoldenFrame.activeTolerance).differingPixels == 0)
            place([-0.55, 0.5, -1])
            let front = try await scene.render(.none)
            #expect(GoldenFrame.compare(baseline, front, tolerance: GoldenFrame.activeTolerance).differingPixels > 500)
            emitter.components[Visibility.self] = .hidden
            let hidden = try await scene.render(.none)
            #expect(GoldenFrame.compare(baseline, hidden, tolerance: GoldenFrame.activeTolerance).differingPixels == 0)
            let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            var graph = try #require(renderWorld.getResource(RenderGraph.self))
            try graph.updateSubgraph(by: .main3D) { _ = $0.removeNode(by: Particles3DRenderNode.name) }
            renderWorld.insertResource(graph)
            let withoutParticlePass = try await scene.render(.none)
            #expect(GoldenFrame.compare(baseline, withoutParticlePass, tolerance: GoldenFrame.activeTolerance).differingPixels == 0,
                "An empty particle pass must preserve the existing graph's image exactly.")
        }
    }
}
#endif
