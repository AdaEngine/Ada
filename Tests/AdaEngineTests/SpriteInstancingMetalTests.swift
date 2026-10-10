#if os(macOS)
@_spi(Internal) import AdaApp
import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
@testable import AdaSprite
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@MainActor
@Suite("Sprite instancing Metal workload", .serialized)
struct SpriteInstancingMetalTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_SPRITE_INSTANCING_BENCHMARK"] == "1"))
    func benchmark() async throws {
        unsafe RenderEngine.configurations.preferredBackend = .metal
        try RenderEngine.setupRenderEngine()
        try #require(unsafe RenderEngine.shared.type == .metal)
        let device = unsafe RenderEngine.shared.renderDevice
        #expect(device.supportsInstancedVertexInputs)
        var pixels: Data?
        var reports: [[String: Double]] = []
        for mode in [SpriteRenderingMode.batched, .automatic] {
            let count = 20_000
            var pipelines = RenderPipelines(configurator: SpriteRenderPipeline())
            let pipeline = pipelines.pipeline(device: device)
            var sprites: [Entity.ID: ExtractedSprite] = [:]
            var items: [Transparent2DRenderItem] = []
            for index in 0..<count {
                let x = Float(index % 200) * 3 - 300
                let y = Float(index / 200) * 3 - 150
                let transform = Transform(position: [x, y, 0])
                sprites[index] = ExtractedSprite(
                    entityId: index,
                    texture: .whiteTexture,
                    size: Size(width: 3, height: 3),
                    flipX: false,
                    flipY: false,
                    tintColor: .white,
                    transform: transform,
                    worldTransform: transform.matrix
                )
                items.append(.init(entity: index, drawPass: SpriteDrawPass(), renderPipeline: pipeline, sortKey: Float(index), batchRange: 0..<0))
            }
            let world = World()
            var data = SpriteDrawData.defaultValue
            data.renderingMode = mode
            world.insertResource(data)
            world.insertResource(SpriteDrawPass())
            world.insertResource(SpriteBatches())
            world.insertResource(ExtractedSprites(sprites: SparseSet(sprites)))
            world.insertResource(AdditionalExtractedSprites())
            world.insertResource(SortedRenderItems(items: RenderItems(items: items)))
            world.insertResource(RenderPipelines(configurator: SpriteRenderPipeline()))
            world.insertResource(RenderDeviceHandler(renderDevice: device))
            world.addSystem(SpriteRenderSystem.self, on: .update)
            let view = world.spawn { Camera() }
            let target = RenderTexture(size: SizeInt(width: 640, height: 360), scaleFactor: 1, format: .bgra8)
            let clock = ContinuousClock()
            var cpu: [Double] = []
            var gpu: [Double] = []
            var bufferIDs: [ObjectIdentifier] = []
            var uploadBytes = 0
            var draws = 0
            for frame in 0..<12 {
                let start = clock.now
                await world.runScheduler(.update)
                let duration = start.duration(to: clock.now).components
                let prepared = try #require(world.getResource(SpriteDrawData.self))
                if frame >= 4 { cpu.append(Double(duration.seconds) + Double(duration.attoseconds) * 1e-18) }
                uploadBytes = prepared.usesInstancing ? prepared.instancing.instances.count * MemoryLayout<SpriteInstanceData>.stride
                    : prepared.vertexBuffer.count * MemoryLayout<SpriteVertexData>.stride + prepared.indexBuffer.count * MemoryLayout<UInt32>.stride
                if prepared.usesInstancing, let buffer = prepared.instancing.instances.buffer { bufferIDs.append(ObjectIdentifier(buffer)) }
                let sorted = try #require(world.getResource(SortedRenderItems<Transparent2DRenderItem>.self))
                draws = sorted.items.items.filter { $0.batchRange?.isEmpty == false }.count
                let command = device.createCommandQueue().makeCommandBuffer()
                let encoder = command.beginRenderPass(RenderPassDescriptor(colorAttachments: [
                    .init(texture: target, operation: OperationDescriptor(loadAction: .clear, storeAction: .store), clearColor: .black)
                ]))
                let projection = Transform3D(scale: [2 / 640, 2 / 360, 0.001])
                encoder.setVertexBuffer(GlobalViewUniform(projectionMatrix: projection, viewProjectionMatrix: projection), slot: GlobalBufferIndex.viewUniform)
                encoder.setViewport(Rect(x: 0, y: 0, width: 640, height: 360))
                try sorted.items.render(with: encoder, world: world, view: view)
                encoder.endRenderPass()
                let elapsed = await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
                    command.addCompletedTimingHandler { continuation.resume(returning: $0) }
                    command.commit()
                }
                if frame >= 4, let elapsed { gpu.append(elapsed) }
            }
            #expect(draws == 1)
            if mode == .automatic {
                let frames = max(1, unsafe RenderEngine.configurations.maxFramesInFlight)
                #expect(Set(bufferIDs).count == frames)
                #expect(bufferIDs[0] == bufferIDs[frames])
                #expect(uploadBytes == count * 96)
            }
            let image = try #require(try await device.readImage(from: target))
            if let pixels { #expect(image.data == pixels) } else { pixels = image.data }
            reports.append([
                "instanced": mode == .automatic ? 1 : 0, "quads": Double(count), "draws": Double(draws), "uploadBytes": Double(uploadBytes),
                "cpuPreparationMs": cpu.reduce(0, +) / Double(cpu.count) * 1000,
                "gpuCommandMs": gpu.isEmpty ? -1 : gpu.reduce(0, +) / Double(gpu.count) * 1000,
            ])
        }
        let encoded = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
        print(String(bytes: encoded, encoding: .utf8) ?? "")
        if let path = ProcessInfo.processInfo.environment["ADAENGINE_SPRITE_INSTANCING_REPORT"] {
            try encoded.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
#endif
