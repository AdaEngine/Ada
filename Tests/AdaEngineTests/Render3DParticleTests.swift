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
