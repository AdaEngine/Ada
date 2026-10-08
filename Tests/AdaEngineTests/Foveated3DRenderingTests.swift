#if os(macOS)
@_spi(Internal) import AdaApp
import AdaEngine
@_spi(Internal) import AdaRender
import Foundation
import Metal
import Testing

/// Run alone: other integration suites initialize the process-wide engine as headless.
@Suite("Foveated 3D Metal scene", .serialized)
@MainActor
struct Foveated3DRenderingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_FOVEATION_METAL_SMOKE"] == "1"))
    func rendersBuiltInGeometryAndScreenSpaceEffectsForBothEyes() async throws {
        unsafe RenderEngine.configurations.preferredBackend = .metal
        try RenderEngine.setupRenderEngine()
        let device = unsafe RenderEngine.shared.renderDevice
        let queue = try #require(MetalInterop.commandQueue(for: device))
        let app = AppWorlds(main: World())
        app.insertResource(OffscreenRenderWorld())
            .insertResource(PrimaryWindowId(windowId: RID()))
            .addPlugin(MainSchedulerPlugin())
            .addPlugin(TransformPlugin())
            .addPlugin(RenderWorldPlugin())
            .addPlugin(EventsPlugin())
            .addPlugin(CameraPlugin())
            .addPlugin(AssetsPlugin(filePath: #filePath))
            .addPlugin(VisibilityPlugin())
            .addPlugin(ScenePlugin())
            .addPlugin(Core3DPlugin())
        try await app.build()
        let target = RenderTexture(size: SizeInt(width: 128, height: 96), scaleFactor: 1, format: .bgra8)
        var environment = Environment3D(ambientOcclusion: .init(isEnabled: true), antiAliasing: .fxaa)
        environment.skybox.isEnabled = false
        environment.screenSpaceReflection.isEnabled = false
        let eye = app.main.spawn(bundle: Camera3D(camera: Camera(renderTarget: target), environment: environment))
        let material = PBRMaterial()
        material.baseColorFactor = [0.8, 0.2, 0.1, 1]
        app.main.spawn {
            Mesh3DComponent(mesh: Mesh.generateCube(size: [1, 1, 1], renderDevice: device), materials: [material])
            Transform(position: [0, 0, 3])
        }
        app.main.spawn {
            DirectionalLightComponent(intensity: 4, castShadows: false)
            Transform()
        }
        func render() async throws -> Image {
            try await app.update()
            let fence = try #require(queue.makeCommandBuffer())
            await withCheckedContinuation { continuation in
                fence.addCompletedHandler { _ in continuation.resume() }
                fence.commit()
            }
            #expect(fence.status == .completed)
            return try #require(device.getImage(from: target))
        }
        let baseline = try await render()
        #expect(baseline.getPixel(x: 64, y: 48) != .black)
        let center = (48 * 128 + 64) * 4
        #expect(baseline.data[center..<center + 3].max() ?? 0 > 64)
        let descriptor = MTLRasterizationRateMapDescriptor(screenSize: MTLSize(width: 128, height: 96, depth: 1))
        for index in 0..<2 {
            let layer = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSize(width: 3, height: 3, depth: 1))
            for sample in 0..<3 {
                layer.horizontal[sample] = index == 0 ? [0.25, 1, 0.5][sample] : [0.5, 1, 0.25][sample]
                layer.vertical[sample] = [0.5, 1, 0.5][sample]
            }
            descriptor.setLayer(layer, at: index)
        }
        let nativeMap = try #require(queue.device.makeRasterizationRateMap(descriptor: descriptor))
        for layer in 0..<2 {
            var camera = try #require(eye.components[Camera.self])
            camera.rasterizationRateMap = try MetalInterop.rasterizationRateMap(nativeMap, layer: layer, reusing: camera.rasterizationRateMap)
            eye.components[Camera.self] = camera
            let image = try await render()
            #expect(image.getPixel(x: 64, y: 48) != .black)
            for y in [44, 48, 52] {
                for x in [60, 64, 68] {
                    for channel in 0..<3 {
                        let offset = (y * 128 + x) * 4 + channel
                        #expect(abs(Int(image.data[offset]) - Int(baseline.data[offset])) < 12)
                    }
                }
            }
            if layer == 1 { try image.writePNG(to: URL(fileURLWithPath: "/tmp/adaengine-foveation-scene.png")) }
        }
        // Removing a frame map must restore ordinary rendering without stale compressed targets.
        var camera = try #require(eye.components[Camera.self])
        camera.rasterizationRateMap = nil
        eye.components[Camera.self] = camera
        let restored = try await render()
        #expect(restored.data == baseline.data)
    }
}
#endif
