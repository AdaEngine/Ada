#if os(macOS)
@_spi(Internal) import AdaApp
@testable import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
@testable import AdaSprite
@testable import AdaTilemap
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

/// Run one backend alone so the process does not share a previously initialized renderer.
@Suite("Sprite layout Metal rendering", .serialized)
@MainActor
struct SpriteMetalRenderingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_SPRITE_METAL_SMOKE"] == "1"))
    func rendersLayoutsAndTileOrientations() async throws {
        let chunks = try await renderReferenceScene(backend: .metal)
        let sprites = try await renderReferenceScene(backend: .metal, tileMapMode: .sprites)
        #expect(chunks.data == sprites.data, "Chunk geometry must preserve the reference renderer's visible pixels.")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_SPRITE_WGPU_SMOKE"] == "1"))
    func rendersLayoutsAndPickingWithWebGPU() async throws {
        let chunks = try await renderReferenceScene(backend: .webgpu)
        let sprites = try await renderReferenceScene(backend: .webgpu, tileMapMode: .sprites)
        #expect(chunks.data == sprites.data, "Chunk geometry must preserve the reference renderer's visible pixels.")
        // Three RGBA pixels require 12 bytes, whereas WebGPU copy rows require 256-byte alignment.
        let device = unsafe RenderEngine.shared.renderDevice
        let target = RenderTexture(size: SizeInt(width: 3, height: 2), scaleFactor: 1, format: .bgra8)
        let command = device.createCommandQueue().makeCommandBuffer()
        let pass = command.beginRenderPass(RenderPassDescriptor(colorAttachments: [
            .init(texture: target, operation: OperationDescriptor(loadAction: .clear, storeAction: .store), clearColor: .red)
        ]))
        pass.endRenderPass()
        command.commit()
        let image = try #require(try await device.readImage(from: target))
        #expect(image.data.count == 24)
        #expect(image.getPixel(x: 0, y: 0) == .red)
        #expect(image.getPixel(x: 2, y: 1) == .red)
        let samplingOnly = Texture2D(image: Image(width: 1, height: 1, color: .white))
        #expect(try await device.readImage(from: samplingOnly) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_SPRITE_METAL_SMOKE"] == "1"))
    func rendersTileOcclusionWithMetal() async throws { try await renderTileOcclusionMask(backend: .metal) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_SPRITE_WGPU_SMOKE"] == "1"))
    func rendersTileOcclusionWithWebGPU() async throws { try await renderTileOcclusionMask(backend: .webgpu) }

    private func renderTileOcclusionMask(backend: RenderBackendType) async throws {
        unsafe RenderEngine.configurations.preferredBackend = backend
        try RenderEngine.setupRenderEngine()
        try #require(unsafe RenderEngine.shared.type == backend)
        TileMapComponent.registerComponent()
        Transform.registerComponent()
        GlobalTransform.registerComponent()
        Visibility.registerComponent()
        BoundingComponent.registerComponent()
        let device = unsafe RenderEngine.shared.renderDevice
        let main = World()
        main.addSystem(TileMapSystem.self)
        main.addSystem(TransformSystem.self, on: .postUpdate)
        let map = TileMap()
        let source = TextureAtlasTileSource(from: Image(width: 16, height: 16, color: .white), size: [16, 16])
        source.createTile(for: [0, 0])
        let sourceID = map.tileSet.addTileSource(source)
        try source.setOccluderPolygon([[-8, -8], [8, -8], [8, 8], [-8, 8]], at: [0, 0], referenceSize: [16, 16])
        for y in [-2, 0, 2] { map.layers[0].setCell(at: [0, y], sourceId: sourceID, atlasCoordinates: [0, 0], orientation: .mirrorX) }
        map.layers[0].setCellOcclusion(.disabled, at: [0, 2])
        map.layers[0].setCellOcclusion(try .polygon([[-8, -8], [8, -8], [0, 8]], referenceSize: [16, 16]), at: [0, -2])
        let owner = main.spawn { TileMapComponent(tileMap: map, tileDisplaySize: [16, 16]); Transform(scale: [-1, 1, 1]) }
        await main.runScheduler(.update)
        await main.runScheduler(.postUpdate)
        #expect(owner.children.isEmpty)
        let render = World()
        render.insertResource(MainWorld(world: main))
        render.insertResource(ExtractedLighting2D())
        render.addSystem(ExtractLighting2DSystem.self, on: .extract)
        render.addSystem(ExtractTileMapOccludersSystem.self, on: .extract)
        await render.runScheduler(.extract)
        let occluders = try #require(render.getResource(ExtractedLighting2D.self)?.occluders)
        #expect(occluders.count == 2)
        var scratch = Lighting2DGPUScratch()
        scratch.prepareShadowVertices(lights: [ExtractedLight2DInstance(
            worldPosition: .zero, kind: .directional, color: .white, energy: 1,
            direction: [1, 0], radius: 64, spotAngle: 0, texture: nil, castsShadows: true
        )], occluders: occluders)
        scratch.shadowVerts.write(to: device)
        let pipelines = Light2DRenderPipelines(device: device)
        let target = RenderTexture(size: [128, 128], scaleFactor: 1, format: .bgra8)
        let command = device.createCommandQueue().makeCommandBuffer()
        let pass = command.beginRenderPass(RenderPassDescriptor(colorAttachments: [
            .init(texture: target, operation: OperationDescriptor(loadAction: .clear, storeAction: .store), clearColor: .white)
        ]))
        let projection = Transform3D(scale: [Float(1) / 64, Float(1) / 64, 0.01])
        pass.setViewport(Rect(x: 0, y: 0, width: 128, height: 128))
        pass.setVertexBuffer(GlobalViewUniform(projectionMatrix: projection, viewProjectionMatrix: projection), slot: GlobalBufferIndex.viewUniform)
        pass.setVertexBuffer(scratch.shadowVerts, offset: 0, slot: 0)
        let white = Texture2D.whiteTexture
        pass.setResourceSet(RenderResourceSet(bindings: [
            .init(binding: 0, shaderStages: .fragment, resource: .texture(white)),
            .init(binding: 1, shaderStages: .fragment, resource: .sampler(white.sampler)),
        ]), index: 0)
        pass.setRenderPipelineState(pipelines.shadowFinPipeline)
        pass.draw(type: .triangle, vertexStart: 0, vertexCount: scratch.shadowVerts.count, instanceCount: 1)
        pass.endRenderPass()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { continuation.resume() }
            command.commit()
        }
        let result = try #require(try await device.readImage(from: target))
        #expect(result.getPixel(x: 110, y: 64) == .black)
        #expect(result.getPixel(x: 110, y: 32) == .white)
        #expect(result.getPixel(x: 110, y: 96) == .black)
        #expect(result.getPixel(x: 16, y: 64) == .white)
        let captureVariable = backend == .webgpu ? "ADAENGINE_TILE_OCCLUSION_WGPU_CAPTURE" : "ADAENGINE_TILE_OCCLUSION_METAL_CAPTURE"
        if let path = ProcessInfo.processInfo.environment[captureVariable] { try result.writePNG(to: URL(fileURLWithPath: path)) }
    }

    private func renderReferenceScene(backend: RenderBackendType, tileMapMode: TileMapRenderMode = .chunks) async throws -> Image {
        unsafe RenderEngine.configurations.preferredBackend = backend
        try RenderEngine.setupRenderEngine()
        try #require(unsafe RenderEngine.shared.type == backend, "Requested GPU backend must be active; fallback is not validation.")
        let device = unsafe RenderEngine.shared.renderDevice
        Sprite.registerComponent()
        TileMapComponent.registerComponent()
        Transform.registerComponent()
        GlobalTransform.registerComponent()
        Visibility.registerComponent()
        BoundingComponent.registerComponent()
        Camera.registerComponent()
        VisibleEntities.registerComponent()
        let mainWorld = World()
        mainWorld.addSystem(TileMapSystem.self, on: .update)
        mainWorld.addSystem(TransformSystem.self, on: .postUpdate)
        mainWorld.addSystem(UpdateBoundingsSystem.self, on: .postUpdate)

        var image = Image(width: 32, height: 16, color: .green)
        image.samplerDescription.magFilter = .nearest
        image.samplerDescription.minFilter = .nearest
        for y in 0..<16 {
            for x in 0..<32 {
                if x < 4 || x >= 28 || y < 4 || y >= 12 {
                    let color: Color = y < 8 ? (x < 16 ? .red : .green) : (x < 16 ? .blue : .yellow)
                    image.setPixel(in: [Float(x), Float(y)], color: color)
                }
            }
        }
        let atlas = TextureAtlas(from: image, size: [32, 16])
        let slice = try #require(atlas.textureSlice(in: RectInt(x: 0, y: 0, width: 32, height: 16)))
        let modes: [SpriteImageMode] = [.stretch, .fit, .fill, .sliced(SpriteSliceBorder(4)), .sliced(SpriteSliceBorder(4)), .tiled()]
        for (index, mode) in modes.enumerated() {
            mainWorld.spawn {
                Sprite(texture: slice, flipX: index == 4, size: Size(width: 64, height: 64), imageMode: mode)
                Transform(position: [Float(index) * 80 - 208, 64, 0])
            }
        }
        mainWorld.spawn {
            Sprite(tintColor: .red, size: Size(width: 16, height: 16), anchor: .bottomLeft)
            Transform(position: [-240, 0, 0])
        }
        let back = mainWorld.spawn {
            Sprite(tintColor: .blue, size: Size(width: 32, height: 16))
            Transform(position: [-200, 0, 0])
        }
        let alphaTexture = Texture2D(image: Image(width: 2, height: 1, data: Data([255, 255, 255, 0, 255, 255, 255, 255])))
        let front = mainWorld.spawn {
            Sprite(texture: alphaTexture, size: Size(width: 32, height: 16))
            Transform(position: [-200, 0, 0.5])
        }

        // A reflected map with two layers must interleave with an ordinary sprite at world Z=1.
        let layeredMap = TileMap()
        let bottomSource = TextureAtlasTileSource(from: Image(width: 1, height: 1, color: .blue), size: [1, 1])
        bottomSource.createTile(for: [0, 0])
        let bottomID = layeredMap.tileSet.addTileSource(bottomSource)
        let topSource = TextureAtlasTileSource(
            from: Image(width: 2, height: 1, data: Data([0, 255, 0, 0, 0, 255, 0, 255])), size: [2, 1]
        )
        topSource.createTile(for: [0, 0])
        let topID = layeredMap.tileSet.addTileSource(topSource)
        layeredMap.layers[0].setCell(at: [0, 0], sourceId: bottomID, atlasCoordinates: [0, 0])
        let topLayer = layeredMap.createLayer()
        topLayer.zIndex = 2
        topLayer.setCell(at: [0, 0], sourceId: topID, atlasCoordinates: [0, 0])
        var layeredComponent = TileMapComponent(tileMap: layeredMap, tileDisplaySize: Size(width: 20, height: 20))
        layeredComponent.renderMode = tileMapMode
        mainWorld.spawn { layeredComponent; Transform(scale: [-1, 1, 1], position: [80, 0, 0]) }
        mainWorld.spawn { Sprite(tintColor: .red, size: Size(width: 20, height: 20)); Transform(position: [80, 0, 1]) }

        let tileMap = TileMap()
        let source = TextureAtlasTileSource(from: image, size: [32, 16])
        source.createTile(for: [0, 0])
        let sourceID = tileMap.tileSet.addTileSource(source)
        for orientation in TileOrientation.allCases {
            tileMap.setCell(for: 0, coordinates: [orientation.rawValue, 0], sourceId: sourceID, atlasCoordinates: [0, 0], orientation: orientation)
        }
        var mapComponent = TileMapComponent(tileMap: tileMap, tileDisplaySize: Size(width: 48, height: 48))
        mapComponent.renderMode = tileMapMode
        mainWorld.spawn {
            mapComponent
            Transform(position: [-224, -64, 0])
        }
        await mainWorld.runScheduler(.update)
        await mainWorld.runScheduler(.postUpdate)

        let world = World()
        world.insertResource(MainWorld(world: mainWorld))
        world.insertResource(ExtractedSprites())
        world.insertResource(AdditionalExtractedSprites())
        world.insertResource(ExtractedTileMapChunks())
        world.insertResource(TileMapChunkGPUCache())
        world.insertResource(TileMapChunkRenderData())
        world.insertResource(RenderPipelines(configurator: TileMapChunkPipeline(from: world)))
        world.insertResource(RenderItems<Transparent2DRenderItem>())
        world.insertResource(SortedRenderItems<Transparent2DRenderItem>())
        world.insertResource(SpriteDrawPass())
        world.insertResource(SpriteBatches())
        world.insertResource(SpriteDrawData.defaultValue)
        world.insertResource(RenderPipelines(configurator: SpriteRenderPipeline()))
        world.insertResource(RenderDeviceHandler(renderDevice: device))
        world.addSystem(ExtractSpriteSystem.self, on: .extract)
        world.addSystem(ExtractTileMapSpritesSystem.self, on: .extract)
        world.addSystem(PrepareSpritesSystem.self, on: .preUpdate)
        world.addSystem(PrepareTileMapChunksSystem.self, on: .preUpdate)
        world.addSystem(Transparent2DBatchingSystem.self, on: .batching)
        world.addSystem(SpriteRenderSystem.self, on: .update)
        let view = world.spawn {
            Camera()
            VisibleEntities(entityIds: Set(mainWorld.getEntities().map(\.id)))
        }
        await world.runScheduler(.extract)
        await world.runScheduler(.preUpdate)
        await world.runScheduler(.batching)
        await world.runScheduler(.update)

        let target = RenderTexture(size: SizeInt(width: 512, height: 256), scaleFactor: 1, format: .bgra8)
        let commandBuffer = device.createCommandQueue().makeCommandBuffer()
        let encoder = commandBuffer.beginRenderPass(RenderPassDescriptor(colorAttachments: [
            .init(texture: target, operation: OperationDescriptor(loadAction: .clear, storeAction: .store), clearColor: .black)
        ]))
        let projection = Transform3D(scale: [Float(2) / 512, Float(2) / 256, 0.01])
        encoder.setVertexBuffer(GlobalViewUniform(projectionMatrix: projection, viewProjectionMatrix: projection), slot: GlobalBufferIndex.viewUniform)
        encoder.setViewport(Rect(x: 0, y: 0, width: 512, height: 256))
        let items = try #require(world.getResource(SortedRenderItems<Transparent2DRenderItem>.self))
        try items.items.render(with: encoder, world: world, view: view)
        encoder.endRenderPass()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { continuation.resume() }
            commandBuffer.commit()
        }
        let result = try #require(try await device.readImage(from: target))
        #expect(result.getPixel(x: 128, y: 40) == .black) // Fit leaves a margin.
        #expect(result.getPixel(x: 128, y: 64) == .green)
        #expect(result.getPixel(x: 257, y: 95) == .blue) // Nine-slice keeps the four-pixel corner.
        #expect(result.getPixel(x: 337, y: 95) == .yellow) // Flip exchanges left/right corners.
        #expect(result.getPixel(x: 30, y: 114) == .red) // Bottom-left anchor shifts geometry into the positive quadrant.
        #expect(result.getPixel(x: 10, y: 124) == .black)
        #expect(result.getPixel(x: 48, y: 128) == .blue)
        #expect(result.getPixel(x: 64, y: 128) == .white)
        #expect(result.getPixel(x: 341, y: 128) == .red)
        #expect(result.getPixel(x: 331, y: 128) == .green)
        let pickingCamera = SpritePickingCamera(entityID: view.id, viewport: Rect(x: 0, y: 0, width: 512, height: 256), projection: projection, worldTransform: .identity)
        let candidates = try [back, front].map { entity in
            SpritePickingCandidate(
                entityID: entity.id,
                sprite: try #require(entity.components[Sprite.self]),
                worldTransform: try #require(entity.components[GlobalTransform.self]).matrix
            )
        }
        #expect(SpritePicker.pick(at: [48, 128], camera: pickingCamera, candidates: candidates).first?.entityID == back.id)
        #expect(SpritePicker.pick(at: [64, 128], camera: pickingCamera, candidates: candidates).first?.entityID == front.id)
        // Every orientation, including reflections, reaches the real draw pass.
        for orientation in TileOrientation.allCases {
            #expect(result.getPixel(x: 32 + orientation.rawValue * 48, y: 192) != .black)
        }
        let captureVariable = backend == .webgpu ? "ADAENGINE_SPRITE_WGPU_CAPTURE" : "ADAENGINE_SPRITE_METAL_CAPTURE"
        if tileMapMode == .chunks, let path = ProcessInfo.processInfo.environment[captureVariable] {
            try result.writePNG(to: URL(fileURLWithPath: path))
        }
        return result
    }
}
#endif
