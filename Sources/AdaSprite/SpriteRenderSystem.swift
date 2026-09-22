//
//  Render2DSystem.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/10/22.
//

import AdaAssets
import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUtils
import Math

// MARK: - Sprite Batching

/// A batch of sprites with the same texture.
public struct SpriteBatch: Sendable {
    /// The texture for this batch.
    public var texture: Texture2D
    /// The range of indices in the index buffer for this batch.
    public var range: Range<Int32>
}

/// A resource that contains all sprite batches for rendering.
public struct SpriteBatches: Resource {
    /// Map from batch entity ID to sprite batch data.
    public var batches: [Entity.ID: SpriteBatch]

    /// Initialize a new sprite batches resource.
    public init(batches: [Entity.ID: SpriteBatch] = [:]) {
        self.batches = batches
    }
}

// MARK: - Extraction to Render World

/// A resource that contains the extracted sprites.
public struct ExtractedSprites: Resource {
    /// The extracted sprites.
    public var sprites: SparseSet<Entity.ID, ExtractedSprite>

    /// Initialize a new extracted sprites.
    ///
    /// - Parameter sprites: The extracted sprites.
    public init(sprites: SparseSet<Entity.ID, ExtractedSprite> = [:]) {
        self.sprites = sprites
    }
}

/// Sprite data contributed by render features that do not materialize one ECS entity per sprite.
public struct AdditionalExtractedSprites: Resource {
    /// Extracted sprites keyed by their frame-local render identifier.
    public var sprites: [Entity.ID: ExtractedSprite]

    /// Initialize additional extracted sprites.
    public init(sprites: [Entity.ID: ExtractedSprite] = [:]) {
        self.sprites = sprites
    }
}

/// A sprite that contains the extracted sprite.
public struct ExtractedSprite: Sendable {
    /// The entity id of the extracted sprite.
    public var entityId: Entity.ID
    /// The texture of the extracted sprite.
    public var texture: Texture2D?
    /// Custom size of extracted sprite.
    public var size: Size?
    /// The flip x of the extracted sprite.
    public var flipX: Bool
    /// The flip y of the extracted sprite.
    public var flipY: Bool
    /// The tint color of the extracted sprite.
    public var tintColor: Color
    /// The transform of the extracted sprite.
    public var transform: Transform
    /// The world transform of the extracted sprite.
    public var worldTransform: Transform3D
    /// The source entity used for per-camera visibility, or `nil` to render for every camera.
    public var visibilityEntityId: Entity.ID?

    /// Initialize an extracted sprite.
    public init(
        entityId: Entity.ID,
        texture: Texture2D?,
        size: Size?,
        flipX: Bool,
        flipY: Bool,
        tintColor: Color,
        transform: Transform,
        worldTransform: Transform3D,
        visibilityEntityId: Entity.ID? = nil
    ) {
        self.entityId = entityId
        self.texture = texture
        self.size = size
        self.flipX = flipX
        self.flipY = flipY
        self.tintColor = tintColor
        self.transform = transform
        self.worldTransform = worldTransform
        self.visibilityEntityId = visibilityEntityId
    }
}

/// A data for drawing sprites.
public struct SpriteDrawData: Resource, DefaultValue {
    public var vertexBuffer: BufferData<SpriteVertexData>
    public var indexBuffer: BufferData<UInt32>

    public static let defaultValue: SpriteDrawData = {
        Self(
            vertexBuffer: .init(label: "SpriteRenderSystem_VertexBuffer", elements: []),
            indexBuffer: .init(label: "SpriteRenderSystem_IndexBuffer", elements: [])
        )
    }()
}

/// Exctract sprites to RenderWorld for future rendering.
@System
@inline(__always)
public func ExtractSprite(
    _: World,
    _ sprites: Extract<
        Query<Entity, Sprite, GlobalTransform, Transform, Visibility>
    >,
    _ extractedSprites: ResMut<ExtractedSprites>
) {
    extractedSprites.sprites.removeAll(keepingCapacity: true)
    sprites.wrappedValue.forEach { entity, sprite, globalTransform, transform, visible in
        if visible == .hidden {
            return
        }
        extractedSprites.sprites[entity.id] = ExtractedSprite(
            entityId: entity.id,
            texture: sprite.texture?.asset,
            size: sprite.size,
            flipX: sprite.flipX,
            flipY: sprite.flipY,
            tintColor: sprite.tintColor,
            transform: transform,
            worldTransform: globalTransform.matrix,
            visibilityEntityId: entity.id
        )
    }
}

@System
@inline(__always)
func UpdateBoundings(
    _ sprites: FilterQuery<
        Entity, Sprite, Ref<BoundingComponent>,
        And<
            With<Sprite>,
            Or<Changed<Transform>, Changed<Sprite>>,
            Without<NoFrustumCulling>
        >,
    >,
    _ meshes: FilterQuery<
        Mesh2D, Ref<BoundingComponent>,
        Or<Changed<Mesh2D>, Without<NoFrustumCulling>>
    >
) async {
    await sprites.parallel()
        .forEach { _, sprite, bounds in
            guard let size = (sprite.size ?? sprite.texture?.asset.size.toSize())?.asVector2 else {
                return
            }
            // Local quad is [-0.5,0.5]×size → centered at origin; AABB must match for frustum culling.
            bounds.bounds = .aabb(
                AABB(
                    center: .zero,
                    halfExtents: Vector3(0.5 * size, 0)
                )
            )
        }

    await meshes.parallel()
        .forEach { mesh2d, bounds in
            bounds.bounds = .aabb(mesh2d.mesh.bounds)
        }
}

@System
func PrepareSprites(
    _ camera: Query<
        Camera,
        VisibleEntities
    >,
    _ renderItems: ResMut<RenderItems<Transparent2DRenderItem>>,
    _ spriteRenderPipeline: ResMut<RenderPipelines<SpriteRenderPipeline>>,
    _ renderDevice: Res<RenderDeviceHandler>,
    _ extractedSprites: Res<ExtractedSprites>,
    _ additionalSprites: Res<AdditionalExtractedSprites>,
    _ spriteDrawPass: Res<SpriteDrawPass>
) {
    camera.forEach { _, entities in
        for sprite in extractedSprites.sprites {
            if !entities.entityIds.contains(sprite.entityId) {
                continue
            }

            let pipeline = spriteRenderPipeline.wrappedValue.pipeline(device: renderDevice.renderDevice)
            renderItems.items.append(
                Transparent2DRenderItem(
                    entity: sprite.entityId,
                    drawPass: spriteDrawPass.wrappedValue,
                    renderPipeline: pipeline,
                    sortKey: sprite.worldTransform.w.z,
                    batchRange: 0..<0
                )
            )
        }

        for sprite in additionalSprites.sprites.values {
            if let visibilityEntityId = sprite.visibilityEntityId,
                !entities.entityIds.contains(visibilityEntityId) {
                continue
            }
            let pipeline = spriteRenderPipeline.wrappedValue.pipeline(device: renderDevice.renderDevice)
            renderItems.items.append(
                Transparent2DRenderItem(
                    entity: sprite.entityId,
                    drawPass: spriteDrawPass.wrappedValue,
                    renderPipeline: pipeline,
                    sortKey: sprite.worldTransform.w.z,
                    batchRange: 0..<0
                )
            )
        }
    }
}

@PlainSystem
public struct SpriteRenderSystem {
    @ResMut<SortedRenderItems<Transparent2DRenderItem>>
    private var renderItems

    @Res
    private var spriteDrawPass: SpriteDrawPass

    @Res<ExtractedSprites>
    private var extractedSprites

    @Res<AdditionalExtractedSprites>
    private var additionalSprites

    @ResMut
    private var spriteRenderPipeline: RenderPipelines<SpriteRenderPipeline>

    @Res
    private var renderDevice: RenderDeviceHandler

    @ResMut
    private var spriteBatches: SpriteBatches

    @ResMut
    private var spriteData: SpriteDrawData

    static let quadPosition: [Vector4] = [
        [-0.5, -0.5, 0.0, 1.0],
        [0.5, -0.5, 0.0, 1.0],
        [0.5, 0.5, 0.0, 1.0],
        [-0.5, 0.5, 0.0, 1.0],
    ]

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        spriteBatches.batches.removeAll(keepingCapacity: true)
        let device = renderDevice.renderDevice

        // Clear previous frame data
        spriteData.vertexBuffer.elements.removeAll(keepingCapacity: true)
        spriteData.indexBuffer.elements.removeAll(keepingCapacity: true)

        var currentTexture: Texture2D?
        var batchStartIndex: Int32 = 0
        var instanceCount: Int32 = 0
        var batchEntityId: Entity.ID?

        func finishCurrentBatch() {
            if let batchEntity = batchEntityId,
                let texture = currentTexture,
                batchStartIndex < instanceCount {
                spriteBatches.batches[batchEntity] = SpriteBatch(
                    texture: texture,
                    range: batchStartIndex..<instanceCount
                )
            }
        }

        for index in renderItems.items.items.indices {
            let renderEntityID = renderItems.items.items[index].entity
            guard let sprite = extractedSprites.sprites[renderEntityID] ?? additionalSprites.sprites[renderEntityID] else {
                finishCurrentBatch()
                currentTexture = nil
                batchEntityId = nil
                batchStartIndex = instanceCount
                continue
            }

            let texture = sprite.texture ?? .whiteTexture
            let worldTransform = sprite.worldTransform

            // Check if we need to start a new batch (texture changed)
            let needsNewBatch = currentTexture.map { !isSameTexture($0, texture) } ?? true

            if needsNewBatch {
                finishCurrentBatch()

                // Start new batch
                currentTexture = texture
                batchStartIndex = instanceCount
                batchEntityId = renderItems.items.items[index].entity
            }

            // Get texture coordinates with flip support
            let textureCoords = getTextureCoordinates(
                texture: texture,
                flipX: sprite.flipX,
                flipY: sprite.flipY
            )

            let size = sprite.size ?? texture.size.toSize()

            // Add sprite vertices (4 vertices per quad)
            let vertexOffset = UInt32(spriteData.vertexBuffer.count)
            for vertexIndex in 0..<Self.quadPosition.count {
                let quadPos = Self.quadPosition[vertexIndex]
                let scaledPosition = Vector4(quadPos.x * size.width, quadPos.y * size.height, quadPos.z, quadPos.w)
                let data = SpriteVertexData(
                    position: worldTransform * scaledPosition,
                    color: sprite.tintColor,
                    textureCoordinate: textureCoords[vertexIndex]
                )
                spriteData.vertexBuffer.append(data)
            }

            // Add indices for this quad (6 indices for 2 triangles)
            // Triangle 1: 0, 1, 2
            // Triangle 2: 2, 3, 0
            spriteData.indexBuffer.append(vertexOffset + 0)
            spriteData.indexBuffer.append(vertexOffset + 1)
            spriteData.indexBuffer.append(vertexOffset + 2)
            spriteData.indexBuffer.append(vertexOffset + 2)
            spriteData.indexBuffer.append(vertexOffset + 3)
            spriteData.indexBuffer.append(vertexOffset + 0)

            instanceCount += 1
        }

        finishCurrentBatch()

        // Early exit if no sprites to render
        if spriteData.vertexBuffer.isEmpty {
            return
        }

        // Write buffers to GPU
        spriteData.vertexBuffer.write(to: device)
        spriteData.indexBuffer.write(to: device)
    }

    // MARK: - Private

    /// Get texture coordinates with flip support.
    @inline(__always)
    private func getTextureCoordinates(
        texture: Texture2D,
        flipX: Bool,
        flipY: Bool
    ) -> [Vector2] {
        var coords = texture.textureCoordinates

        if flipX {
            // Swap left and right coordinates
            coords.swapAt(0, 1)
            coords.swapAt(2, 3)
        }

        if flipY {
            // Swap top and bottom coordinates
            coords.swapAt(0, 3)
            coords.swapAt(1, 2)
        }

        return coords
    }

    func isSameTexture(_ lhs: Texture2D, _ rhs: Texture2D) -> Bool {
        return lhs.gpuTexture === rhs.gpuTexture && lhs.sampler === rhs.sampler
    }
}
