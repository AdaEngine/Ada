#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaApp
@testable import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import Math
import Testing

extension Render3DGPUTests {
    @MainActor
    @Suite("Shadow cache lifetime through deferred camera extraction", .enabled(if: GoldenFrame.isEnabled))
    struct ShadowCacheLifetime {
        private static func fixture() async throws -> MeshletBaselineFixtures.Scene {
            let scene = try await MeshletBaselineFixtures.empty(size: [96, 64], shadows: true)
            var environment = try #require(scene.camera.components[Environment3D.self])
            environment.localShadows = .init(maximumLights: 4, resolution: 128)
            environment.shadows.resolution = 128
            environment.gpuOcclusionEnabled = false
            environment.meshVisibility.meshlets = .gpu
            scene.camera.components[Environment3D.self] = environment
            let materials = (0..<16).map { _ in PBRMaterial() }
            materials[0].alphaMode = .mask
            let mesh = Mesh.generateCube(renderDevice: scene.device)
            for index in 0..<4 {
                scene.app.main.spawn("Static shared-table caster \(index)") {
                    Mesh3DComponent(mesh: mesh, materials: materials)
                    Transform(position: [Float(index) - 1.5, 0, 3])
                }
                scene.app.main.spawn("Static cached spotlight \(index)") {
                    SpotLightComponent(intensity: 5, castShadows: true, range: 10)
                    Transform(position: [Float(index) - 1.5, 0, 0])
                }
            }
            return scene
        }

        private static func completeFrame(_ scene: MeshletBaselineFixtures.Scene, frames: Int = 1) async throws {
            for _ in 0..<frames { try await scene.app.update() }
            _ = try #require(try await scene.device.readImage(from: scene.target))
        }

        @Test
        func deferredProxyKeepsActualAtlasUntilSourceCameraIsRemoved() async throws {
            let scene = try await Self.fixture()
            try await Self.completeFrame(scene, frames: 4)
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            let sourceID = scene.camera.id
            let targets = try #require(world.getResource(ExtractedCameraRenderViewTargets.self))
            #expect(targets.activeCameraIDs.contains(sourceID))
            let original = try #require(world.getResource(LocalShadow3DViews.self)?.entries[sourceID])
            #expect(original.allocator.slots.count == 4 && original.faceDigests.count == 4)
            #expect(original.renderedFaces == 0 && original.reusedFaces == 4)
            let atlas = try #require(original.color), depth = try #require(original.depth)
            let proxy = try #require(world.getEntities().first { $0.components[ExtractedCameraSource.self]?.entityId == sourceID })
            let camera = try #require(proxy.components[Camera.self])
            let uniform = try #require(proxy.components[GlobalViewUniform.self])
            proxy.components[Camera.self] = nil
            proxy.components[GlobalViewUniform.self] = nil
            let node = LocalShadow3DRenderNode()
            // This is the production update that used to retire an active camera's atlas during backpressure.
            for _ in 0..<3 { node.update(from: world) }
            let retained = try #require(world.getResource(LocalShadow3DViews.self)?.entries[sourceID])
            #expect(retained.color === atlas && retained.depth === depth)
            #expect(retained.faceDigests == original.faceDigests && retained.faceMatrixDigests == original.faceMatrixDigests)
            #expect(retained.sceneDigest == original.sceneDigest && retained.allocator.slots == original.allocator.slots)
            proxy.components[Camera.self] = camera
            proxy.components[GlobalViewUniform.self] = uniform
            try await Self.completeFrame(scene)
            let resumed = try #require(world.getResource(LocalShadow3DViews.self)?.entries[sourceID])
            #expect(resumed.color === atlas && resumed.depth === depth)
            #expect(resumed.renderedFaces == 0 && resumed.reusedFaces == 4,
                "Resuming extraction must reuse the cached faces rather than allocate and redraw the atlas.")
            scene.camera.components[Camera.self] = nil
            try await scene.app.update()
            node.update(from: world)
            #expect(try #require(world.getResource(ExtractedCameraRenderViewTargets.self)).activeCameraIDs.contains(sourceID) == false)
            #expect(world.getResource(LocalShadow3DViews.self)?.entries[sourceID] == nil,
                "Authoritative camera deletion must still retire the cached atlas.")
        }

        @Test
        func cameraTemporalAndMeshletChangesKeepStaticLightFaces() async throws {
            let scene = try await Self.fixture()
            try await Self.completeFrame(scene, frames: 4)
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            let original = try #require(world.getResource(LocalShadow3DViews.self)?.entries[scene.camera.id])
            let atlas = try #require(original.color), depth = try #require(original.depth)
            let scales: [Float?] = [0.5, 0.75, nil, 0.5]
            for (index, scale) in scales.enumerated() {
                var camera = try #require(scene.camera.components[Camera.self])
                camera.temporalUpscaling = scale.map { .init(renderScale: $0, method: .portable) }
                scene.camera.components[Camera.self] = camera
                scene.camera.components[Transform.self] = Transform(rotation: Quat(axis: .up, angle: Float(index) * 0.01), position: [0, 0, -10])
                var environment = try #require(scene.camera.components[Environment3D.self])
                environment.meshVisibility.meshletLODPixelError = index.isMultiple(of: 2) ? 0 : 2
                scene.camera.components[Environment3D.self] = environment
                try await Self.completeFrame(scene)
                let retained = try #require(world.getResource(LocalShadow3DViews.self)?.entries[scene.camera.id])
                #expect(retained.color === atlas && retained.depth === depth)
                #expect(retained.sceneDigest == original.sceneDigest && retained.faceDigests == original.faceDigests)
                #expect(retained.renderedFaces == 0 && retained.reusedFaces == 4,
                    "Camera motion, temporal input scale and meshlet LOD settings cannot dirty static local-light faces.")
            }
        }
    }
}
#endif
