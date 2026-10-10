import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaSprite
import AdaTransform
import AdaUtils
import Foundation
import Math

/// Shared GPU readback fixture for native/mobile Metal and browser WebGPU.
@MainActor
enum SpriteValidationFixture {
    struct Result {
        let image: Image
        let backend: RenderBackendType
        let draws: Int
        let quads: Int
    }

    enum Failure: Error {
        case unsupportedBackend, missingResource, missingImage, unequalPixels, emptyImage, missingInstancing
    }

    static func run() async throws -> Result {
        let device = unsafe RenderEngine.shared.renderDevice
        guard device.supportsInstancedVertexInputs else { throw Failure.unsupportedBackend }
        Camera.registerComponent()
        let world = World()
        world.insertResource(SpriteDrawPass())
        world.insertResource(SpriteBatches())
        world.insertResource(AdditionalExtractedSprites())
        world.insertResource(RenderDeviceHandler(renderDevice: device))
        world.insertResource(RenderPipelines(configurator: SpriteRenderPipeline()))
        world.addSystem(SpriteRenderSystem.self, on: .update)
        let view = world.spawn { Camera() }
        let target = RenderTexture(size: [640, 360], scaleFactor: 1, format: .bgra8)
        var pipelines = RenderPipelines(configurator: SpriteRenderPipeline())
        let pipeline = pipelines.pipeline(device: device)
        var sprites: [Entity.ID: ExtractedSprite] = [:]
        var items: [Transparent2DRenderItem] = []
        var atlasImage = Image(width: 32, height: 16, color: .green)
        atlasImage.samplerDescription.magFilter = .nearest
        atlasImage.samplerDescription.minFilter = .nearest
        for y in 0..<16 {
            for x in 0..<32 where x < 4 || x >= 28 || y < 4 || y >= 12 {
                atlasImage.setPixel(in: [Float(x), Float(y)], color: y < 8 ? (x < 16 ? .red : .yellow) : (x < 16 ? .blue : .white))
            }
        }
        let atlas = TextureAtlas(from: atlasImage, size: [32, 16])
        guard let slice = atlas.textureSlice(in: RectInt(x: 0, y: 0, width: 32, height: 16)) else { throw Failure.missingImage }
        let alphaTexture = Texture2D(image: Image(width: 2, height: 1, data: Data([255, 255, 255, 0, 255, 255, 255, 128])))
        func add(
            texture: Texture2D,
            position: Vector3,
            size: Size,
            mode: SpriteImageMode = .stretch,
            anchor: SpriteAnchor = .center,
            flipX: Bool = false,
            flipY: Bool = false,
            color: Color = .white,
            scale: Vector3 = [1, 1, 1],
            rotation: Quat = .identity
        ) {
            let id = sprites.count
            let transform = Transform(rotation: rotation, scale: scale, position: position)
            sprites[id] = ExtractedSprite(
                entityId: id,
                texture: texture,
                size: size,
                flipX: flipX,
                flipY: flipY,
                tintColor: color,
                transform: transform,
                worldTransform: transform.matrix,
                anchor: anchor,
                imageMode: mode
            )
            items.append(.init(entity: id, drawPass: SpriteDrawPass(), renderPipeline: pipeline, sortKey: Float(id), batchRange: 0..<0))
        }
        let modes: [SpriteImageMode] = [.stretch, .fit, .fill, .sliced(SpriteSliceBorder(4)), .sliced(SpriteSliceBorder(4)), .tiled()]
        for (index, mode) in modes.enumerated() {
            add(
                texture: slice,
                position: [Float(index) * 96 - 240, 112, 0],
                size: [72, 72],
                mode: mode,
                flipX: index == 4,
                flipY: index == 5
            )
        }
        add(texture: .whiteTexture, position: [-280, 8, 0], size: [40, 40], anchor: .bottomLeft, color: .red)
        add(texture: slice, position: [-170, 28, 0], size: [96, 48], scale: [-1, 1, 1], rotation: Quat(axis: [0, 0, 1], angle: 0.2))
        add(texture: .whiteTexture, position: [-32, 28, 0], size: [72, 48], color: .blue)
        add(texture: alphaTexture, position: [-32, 28, 0], size: [72, 48])
        add(texture: .whiteTexture, position: [64, 28, 0], size: [72, 48], color: .red)
        add(texture: alphaTexture, position: [64, 28, 0], size: [72, 48])
        // A long contiguous run exercises instance offsets and buffer reuse across frames.
        for index in 0..<1200 {
            add(
                texture: .whiteTexture,
                position: [Float(index % 120) * 5 - 298, Float(index / 120) * 5 - 120, 0],
                size: [3, 3],
                color: index % 2 == 0 ? .green : .yellow
            )
        }
        world.insertResource(ExtractedSprites(sprites: SparseSet(sprites)))
        var reference: Data?
        var resultImage: Image?
        var draws = 0
        var quads = 0
        for mode in [SpriteRenderingMode.batched, .automatic] {
            var data = SpriteDrawData.defaultValue
            data.renderingMode = mode
            world.insertResource(data)
            for _ in 0..<5 {
                world.insertResource(SortedRenderItems(items: RenderItems(items: items)))
                await world.runScheduler(.update)
                guard let prepared = world.getResource(SpriteDrawData.self),
                    let sorted = world.getResource(SortedRenderItems<Transparent2DRenderItem>.self)
                else { throw Failure.missingResource }
                if mode == .automatic, !prepared.vertexBuffer.isEmpty { throw Failure.missingInstancing }
                draws = sorted.items.items.filter { $0.batchRange?.isEmpty == false }.count
                quads = world.getResource(SpriteBatches.self)?.batches.values.reduce(0) { $0 + $1.range.count } ?? 0
                let command = device.createCommandQueue().makeCommandBuffer()
                let encoder = command.beginRenderPass(
                    RenderPassDescriptor(colorAttachments: [
                        .init(texture: target, operation: OperationDescriptor(loadAction: .clear, storeAction: .store), clearColor: .black)
                    ])
                )
                let projection = Transform3D(scale: [Float(2) / 640, Float(2) / 360, 0.001])
                encoder.setVertexBuffer(GlobalViewUniform(projectionMatrix: projection, viewProjectionMatrix: projection), slot: GlobalBufferIndex.viewUniform)
                encoder.setViewport(Rect(x: 0, y: 0, width: 640, height: 360))
                try sorted.items.render(with: encoder, world: world, view: view)
                encoder.endRenderPass()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    command.addCompletedHandler { continuation.resume() }
                    command.commit()
                }
                guard let image = try await device.readImage(from: target) else { throw Failure.missingImage }
                if let reference, image.data != reference { throw Failure.unequalPixels }
                reference = image.data
                resultImage = image
            }
        }
        guard let image = resultImage else { throw Failure.missingImage }
        guard image.getPixel(x: 50, y: 150) == .red, image.getPixel(x: 260, y: 150) == .blue,
            image.getPixel(x: 356, y: 150) == .red, image.getPixel(x: 22, y: 300) == .green,
            quads >= 1200, draws > 1
        else { throw Failure.emptyImage }
        let backend = unsafe RenderEngine.shared.type
        print("[SpriteValidation] PASS backend=\(backend) pixels=identical frames=10 quads=\(quads) draws=\(draws) instancing=true")
        return Result(image: image, backend: backend, draws: draws, quads: quads)
    }
}
