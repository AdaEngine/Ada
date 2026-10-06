import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaSprite
import AdaTransform
import AdaUtils
import Math

struct TileMapChunkTextureKey: Hashable {
    let texture: ObjectIdentifier
    let sampler: ObjectIdentifier
}

struct TileMapChunkTextureBatch: Sendable {
    let texture: Texture2D
    let range: Range<Int>
}

struct TileMapChunkGeometry: Sendable {
    // Retain source identity so an address cannot be reused for stale geometry.
    let source: TileMapRenderedChunk
    let vertices: BufferData<SpriteVertexData>
    let indices: BufferData<UInt32>
    let batches: [TileMapChunkTextureBatch]

    init(source: TileMapRenderedChunk, device: RenderDevice) {
        self.source = source
        var groups: [TileMapChunkTextureKey: [TileMapRenderedAtlasTile]] = [:]
        var order: [TileMapChunkTextureKey] = []
        for tile in source.atlasTiles {
            let key = TileMapChunkTextureKey(texture: ObjectIdentifier(tile.texture.gpuTexture), sampler: ObjectIdentifier(tile.texture.sampler))
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(tile)
        }
        var vertices = BufferData<SpriteVertexData>(elements: [])
        var indices = BufferData<UInt32>(elements: [])
        var batches: [TileMapChunkTextureBatch] = []
        for key in order {
            guard let tiles = groups[key], let texture = tiles.first?.texture else {
                continue
            }
            let start = indices.count
            for tile in tiles {
                let offset = UInt32(vertices.count)
                let corners: [Vector4] = [
                    [-0.5, -0.5, 0, 1], [0.5, -0.5, 0, 1], [0.5, 0.5, 0, 1], [-0.5, 0.5, 0, 1]
                ]
                for index in corners.indices {
                    let corner = corners[index]
                    vertices.append(SpriteVertexData(
                        position: tile.transform.matrix * Vector4(corner.x * source.tileSize.width, corner.y * source.tileSize.height, 0, 1),
                        color: tile.tintColor,
                        textureCoordinate: tile.texture.textureCoordinates[index]
                    ))
                }
                for index: UInt32 in [0, 1, 2, 2, 3, 0] { indices.append(offset + index) }
            }
            batches.append(TileMapChunkTextureBatch(texture: texture, range: start..<indices.count))
        }
        vertices.write(to: device)
        indices.write(to: device)
        self.vertices = vertices
        self.indices = indices
        self.batches = batches
    }
}

struct TileMapChunkGPUCache: Resource {
    var geometries: [ObjectIdentifier: TileMapChunkGeometry] = [:]
}

struct TileMapChunkDrawInstance: Sendable {
    let cameraID: Entity.ID
    let chunkID: ObjectIdentifier
    let model: Transform3D
}

struct TileMapChunkRenderData: Resource {
    var instances: [Entity.ID: TileMapChunkDrawInstance] = [:]
    var visibleChunks = 0
    var uploadedBytes = 0
    var rebuiltChunks = 0
}

@PlainSystem
struct PrepareTileMapChunksSystem {
    @Query<Entity, Camera, VisibleEntities> private var cameras
    @Res<ExtractedTileMapChunks> private var chunks
    @Res<RenderDeviceHandler> private var device
    @ResMut<RenderPipelines<TileMapChunkPipeline>> private var pipelines
    @ResMut<TileMapChunkGPUCache> private var cache
    @ResMut<TileMapChunkRenderData> private var draws
    @ResMut<RenderItems<Transparent2DRenderItem>> private var items

    init(world _: World) {}

    func update(context _: UpdateContext) {
        draws.instances.removeAll(keepingCapacity: true)
        draws.visibleChunks = 0
        draws.uploadedBytes = 0
        draws.rebuiltChunks = 0
        let activeIDs = Set(chunks.chunks.map { ObjectIdentifier($0.chunk) })
        for key in Array(cache.geometries.keys) where !activeIDs.contains(key) { cache.geometries[key] = nil }
        var renderID = Int.min / 2
        cameras.forEach { entity, camera, visible in
            guard camera.isActive else {
                return
            }
            for instance in chunks.chunks {
                guard visible.entityIds.contains(instance.ownerID) else {
                    continue
                }
                if !instance.ignoresFrustum, !camera.computedData.frustum.intersectsAABB(instance.chunk.worldBounds(model: instance.model)) {
                    continue
                }
                let key = ObjectIdentifier(instance.chunk)
                if cache.geometries[key] == nil {
                    let geometry = TileMapChunkGeometry(source: instance.chunk, device: device.renderDevice)
                    cache.geometries[key] = geometry
                    draws.rebuiltChunks += 1
                    draws.uploadedBytes += geometry.vertices.count * MemoryLayout<SpriteVertexData>.stride + geometry.indices.count * MemoryLayout<UInt32>.stride
                }
                draws.instances[renderID] = TileMapChunkDrawInstance(cameraID: entity.id, chunkID: key, model: instance.model)
                let localZ = Float(instance.chunk.bounds.center.z)
                let sortKey = (instance.model * Vector4(0, 0, localZ, 1)).z
                let pipeline = pipelines.pipeline(device: device.renderDevice)
                items.items.append(Transparent2DRenderItem(entity: renderID, drawPass: TileMapChunkDrawPass(), renderPipeline: pipeline, sortKey: sortKey))
                renderID &+= 1
                draws.visibleChunks += 1
            }
        }
    }
}

struct TileMapChunkDrawPass: DrawPass {
    func render(with encoder: RenderCommandEncoder, world: World, view: Entity, item: Transparent2DRenderItem) throws {
        guard let instance = world.getResource(TileMapChunkRenderData.self)?.instances[item.entity],
            instance.cameraID == view.id,
            let geometry = world.getResource(TileMapChunkGPUCache.self)?.geometries[instance.chunkID] else {
                return
            }
        encoder.setRenderPipelineState(item.renderPipeline)
        encoder.setVertexBuffer(geometry.vertices, offset: 0, slot: 0)
        encoder.setIndexBuffer(geometry.indices, indexFormat: .uInt32)
        encoder.setVertexBuffer(instance.model, slot: 3)
        for batch in geometry.batches {
            encoder.setResourceSet(RenderResourceSet(bindings: [
                .init(binding: 0, shaderStages: .fragment, resource: .texture(batch.texture)),
                .init(binding: 1, shaderStages: .fragment, resource: .sampler(batch.texture.sampler))
            ]), index: 0)
            encoder.drawIndexed(indexCount: batch.range.count, indexBufferOffset: batch.range.lowerBound * MemoryLayout<UInt32>.stride, instanceCount: 1)
        }
    }
}
