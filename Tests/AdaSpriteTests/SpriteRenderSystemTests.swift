import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
@testable import AdaSprite
import AdaTransform
import AdaUtils
import Math
import Testing

@MainActor
@Suite("Sprite render system")
struct SpriteRenderSystemTests {
    @Test("Sprite depth sorting includes its parent transform")
    func depthSortingUsesWorldPosition() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()
        Camera.registerComponent()
        VisibleEntities.registerComponent()
        let sprite = ExtractedSprite(
            entityId: 101,
            texture: .whiteTexture,
            size: nil,
            flipX: false,
            flipY: false,
            tintColor: .white,
            transform: Transform(position: [0, 0, 2]),
            worldTransform: Transform3D(translation: [0, 0, 12])
        )
        let world = try Self.makeRenderWorld(extractedSprites: [101: sprite], items: [])
        world.insertResource(RenderItems<Transparent2DRenderItem>())
        world.addSystem(PrepareSpritesSystem.self, on: .preUpdate)
        world.spawn {
            Camera()
            VisibleEntities(entityIds: [101])
        }

        await world.runScheduler(.preUpdate)

        let items = try #require(world.getResource(RenderItems<Transparent2DRenderItem>.self))
        #expect(items.items.count == 1)
        #expect(items.items.first?.sortKey == 12)
    }

    @Test("Additional extracted sprites render without backing ECS entities")
    func additionalExtractedSpritesArePrepared() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()
        Camera.registerComponent()
        VisibleEntities.registerComponent()
        let renderID = Int.min
        let sprite = Self.extractedSprite(id: renderID, texture: .whiteTexture)
        let world = try Self.makeRenderWorld(extractedSprites: [:], items: [])
        world.insertResource(AdditionalExtractedSprites(sprites: [renderID: sprite]))
        world.insertResource(RenderItems<Transparent2DRenderItem>())
        world.addSystem(PrepareSpritesSystem.self, on: .preUpdate)
        world.spawn {
            Camera()
            VisibleEntities()
        }

        await world.runScheduler(.preUpdate)

        let items = try #require(world.getResource(RenderItems<Transparent2DRenderItem>.self))
        #expect(items.items.map(\.entity) == [renderID])
    }

    @Test("A non-sprite item separates sprite batches")
    func nonSpriteItemsSeparateSpriteBatches() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let firstSpriteID = 1
        let textID = 2
        let secondSpriteID = 3
        let texture = Texture2D.whiteTexture
        let extractedSprites = [
            firstSpriteID: Self.extractedSprite(id: firstSpriteID, texture: texture),
            secondSpriteID: Self.extractedSprite(id: secondSpriteID, texture: texture)
        ]
        let pipeline = try Self.makePipeline()
        let items = [
            Self.item(
                entity: firstSpriteID,
                drawPass: SpriteDrawPass(),
                renderPipeline: pipeline,
                sortKey: 0,
                batchRange: 0..<0
            ),
            Self.item(
                entity: textID,
                drawPass: TextDrawPass(),
                renderPipeline: pipeline,
                sortKey: 1,
                batchRange: 0..<0
            ),
            Self.item(
                entity: secondSpriteID,
                drawPass: SpriteDrawPass(),
                renderPipeline: pipeline,
                sortKey: 2,
                batchRange: 0..<0
            )
        ]
        let world = try Self.makeRenderWorld(
            extractedSprites: extractedSprites,
            items: items
        )

        await world.runScheduler(.update)

        let batches = try #require(world.getResource(SpriteBatches.self))
        #expect(batches.batches[firstSpriteID]?.range == 0..<1)
        #expect(batches.batches[secondSpriteID]?.range == 1..<2)
        #expect(batches.batches[textID] == nil)
    }

    @Test("Sprites sharing an atlas retain their natural sizes")
    func atlasSlicesUseTheirOwnNaturalSizes() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let atlas = TextureAtlas(
            from: Image(width: 32, height: 32, color: .white),
            size: [8, 8]
        )
        let smallSlice = TextureAtlas.Slice(
            atlas: atlas,
            min: [0, 0],
            max: [0.25, 0.25],
            size: [8, 8]
        )
        let largeSlice = TextureAtlas.Slice(
            atlas: atlas,
            min: [0.25, 0],
            max: [0.75, 0.5],
            size: [16, 16]
        )
        #expect(smallSlice.gpuTexture === largeSlice.gpuTexture)
        #expect(smallSlice.sampler === largeSlice.sampler)
        let firstSpriteID = 10
        let secondSpriteID = 11
        let pipeline = try Self.makePipeline()
        let items = [
            Self.item(
                entity: firstSpriteID,
                drawPass: SpriteDrawPass(),
                renderPipeline: pipeline,
                sortKey: 0,
                batchRange: 0..<0
            ),
            Self.item(
                entity: secondSpriteID,
                drawPass: SpriteDrawPass(),
                renderPipeline: pipeline,
                sortKey: 1,
                batchRange: 0..<0
            )
        ]
        let world = try Self.makeRenderWorld(
            extractedSprites: [
                firstSpriteID: Self.extractedSprite(id: firstSpriteID, texture: smallSlice),
                secondSpriteID: Self.extractedSprite(id: secondSpriteID, texture: largeSlice)
            ],
            items: items
        )

        await world.runScheduler(.update)

        let drawData = try #require(world.getResource(SpriteDrawData.self))
        let vertices = drawData.vertexBuffer.elements
        #expect(vertices.count == 8)
        guard vertices.count == 8 else {
            return
        }
        #expect(vertices[1].position.x == 4)
        #expect(vertices[5].position.x == 8)

        let batches = try #require(world.getResource(SpriteBatches.self))
        #expect(batches.batches.count == 1)
        #expect(batches.batches[firstSpriteID]?.range == 0..<2)
    }

    @Test("Stationary sprite size changes update culling bounds")
    func spriteSizeChangesUpdateBounds() async throws {
        Sprite.registerComponent()
        BoundingComponent.registerComponent()
        NoFrustumCulling.registerComponent()
        Transform.registerComponent()
        GlobalTransform.registerComponent()
        Visibility.registerComponent()

        let world = World()
        world.addSystem(UpdateBoundingsSystem.self, on: .postUpdate)
        let entity = world.spawn {
            Sprite(size: Size(width: 8, height: 10))
            Transform()
        }

        await world.runScheduler(.postUpdate)
        world.clearTrackers()
        entity.components[Sprite.self]?.size = Size(width: 20, height: 30)

        await world.runScheduler(.postUpdate)

        let bounds = try #require(entity.components[BoundingComponent.self]?.bounds)
        guard case let .aabb(aabb) = bounds else {
            Issue.record("Sprite bounds should be an AABB")
            return
        }
        #expect(aabb.halfExtents == Vector3(10, 15, 0))
    }

    @Test("Bottom-left anchors and flips retain the parent world transform")
    func anchorAndFlipGeometry() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()
        var sprite = Self.extractedSprite(id: 1, texture: .whiteTexture)
        sprite.size = Size(width: 20, height: 10)
        sprite.anchor = .bottomLeft
        sprite.flipX = true
        sprite.worldTransform = Transform3D(translation: [3, 4, 2], rotation: .identity, scale: [2, 3, 1])
        let (vertices, _) = try await Self.render(sprite)
        #expect(vertices.count == 4)
        #expect(vertices[0].position == Vector4(3, 4, 2, 1))
        #expect(vertices[2].position == Vector4(43, 34, 2, 1))
        #expect(vertices[0].textureCoordinate.x == 1)
    }

    @Test("Anchor changes update stationary culling bounds")
    func anchorChangesUpdateBounds() async throws {
        Sprite.registerComponent()
        BoundingComponent.registerComponent()
        NoFrustumCulling.registerComponent()
        Transform.registerComponent()
        GlobalTransform.registerComponent()
        Visibility.registerComponent()
        let world = World()
        world.addSystem(UpdateBoundingsSystem.self, on: .postUpdate)
        let entity = world.spawn {
            Sprite(size: Size(width: 20, height: 30))
            Transform()
        }
        await world.runScheduler(.postUpdate)
        world.clearTrackers()
        entity.components[Sprite.self]?.anchor = .bottomLeft
        await world.runScheduler(.postUpdate)
        let bounds = try #require(entity.components[BoundingComponent.self]?.bounds)
        guard case let .aabb(aabb) = bounds else {
            Issue.record("Expected sprite AABB")
            return
        }
        #expect(aabb.center == Vector3(10, 15, 0))
        #expect(aabb.halfExtents == Vector3(10, 15, 0))
    }

    @Test("Fit preserves aspect ratio and fill crops within an atlas entry")
    func aspectModesUseAtlasUVs() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()
        let atlas = TextureAtlas(from: Image(width: 80, height: 40, color: .white), size: [20, 10])
        let slice = try #require(atlas.textureSlice(in: RectInt(x: 20, y: 10, width: 20, height: 10)))
        var sprite = Self.extractedSprite(id: 1, texture: slice)
        sprite.size = Size(width: 40, height: 40)
        sprite.imageMode = .fit
        let (fit, _) = try await Self.render(sprite)
        #expect(fit[0].position == Vector4(-20, -10, 0, 1))
        #expect(fit[2].position == Vector4(20, 10, 0, 1))
        sprite.imageMode = .fill
        let (fill, _) = try await Self.render(sprite)
        #expect(fill[0].position == Vector4(-20, -20, 0, 1))
        #expect(fill[2].position == Vector4(20, 20, 0, 1))
        #expect(abs(fill[0].textureCoordinate.x - 0.3125) < 0.0001)
        #expect(abs(fill[2].textureCoordinate.x - 0.4375) < 0.0001)
        #expect(abs(fill[0].textureCoordinate.y - 0.5) < 0.0001)
        #expect(abs(fill[2].textureCoordinate.y - 0.25) < 0.0001)
    }

    @Test("Nine-slice borders keep their size, including asymmetric flips")
    func nineSliceBordersAndFlip() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()
        let texture = Texture2D(image: Image(width: 20, height: 10, color: .white))
        var sprite = Self.extractedSprite(id: 1, texture: texture)
        sprite.size = Size(width: 60, height: 30)
        sprite.anchor = .bottomLeft
        sprite.imageMode = .sliced(SpriteSliceBorder(top: 1, left: 2, bottom: 3, right: 5))
        let (vertices, batches) = try await Self.render(sprite)
        #expect(vertices.count == 36)
        #expect(vertices[2].position == Vector4(2, 3, 0, 1))
        #expect(vertices[6].position == Vector4(55, 3, 0, 1))
        #expect(vertices[34].position == Vector4(60, 30, 0, 1))
        #expect(batches.batches[1]?.range == 0..<9)
        sprite.flipX = true
        sprite.flipY = true
        let (flipped, _) = try await Self.render(sprite)
        #expect(flipped[2].position == Vector4(5, 1, 0, 1))
        #expect(abs(flipped[0].textureCoordinate.x - 1) < 0.0001)
        #expect(abs(flipped[2].textureCoordinate.x - 0.75) < 0.0001)
        #expect(abs(flipped[2].textureCoordinate.y - 0.1) < 0.0001)
    }

    @Test("Undersized nine-slice corners shrink proportionally without overlap")
    func smallNineSliceDestination() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()
        var sprite = Self.extractedSprite(id: 1, texture: Texture2D(image: Image(width: 20, height: 20, color: .white)))
        sprite.size = Size(width: 4, height: 4)
        sprite.anchor = .bottomLeft
        sprite.imageMode = .sliced(SpriteSliceBorder(4))
        let (vertices, _) = try await Self.render(sprite)
        #expect(vertices.count == 16)
        #expect(vertices[2].position == Vector4(2, 2, 0, 1))
        #expect(vertices[14].position == Vector4(4, 4, 0, 1))
    }

    @Test("Partial repetitions stay inside their atlas region")
    func tiledAtlasPartialQuad() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()
        let atlas = TextureAtlas(from: Image(width: 32, height: 16, color: .white), size: [8, 8])
        let slice = try #require(atlas.textureSlice(in: RectInt(x: 8, y: 0, width: 8, height: 8)))
        var sprite = Self.extractedSprite(id: 1, texture: slice)
        sprite.size = Size(width: 20, height: 12)
        sprite.anchor = .bottomLeft
        sprite.imageMode = .tiled()
        let (vertices, batches) = try await Self.render(sprite)
        #expect(vertices.count == 24)
        #expect(vertices[22].position == Vector4(20, 12, 0, 1))
        #expect(vertices[22].textureCoordinate == Vector2(0.375, 0.25))
        #expect(batches.batches[1]?.range == 0..<6)
        sprite.imageMode = .tiled(tileX: true, tileY: false, scale: 2)
        let (oneAxis, _) = try await Self.render(sprite)
        #expect(oneAxis.count == 8)
        #expect(oneAxis[6].position == Vector4(20, 12, 0, 1))
    }

    @Test("Invalid layout emits no geometry and tiny tiles have a bounded fallback")
    func invalidLayoutAndTileBudget() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()
        var sprite = Self.extractedSprite(id: 1, texture: .whiteTexture)
        for size in [Size(width: .infinity, height: 1), Size(width: -1, height: 2), .zero] {
            sprite.size = size
            let (vertices, batches) = try await Self.render(sprite)
            #expect(vertices.isEmpty)
            #expect(batches.batches.isEmpty)
        }
        sprite.size = Size(width: 100, height: 100)
        sprite.imageMode = .tiled(scale: 0)
        let (invalid, _) = try await Self.render(sprite)
        #expect(invalid.isEmpty)
        sprite.imageMode = .tiled(scale: 0.000001)
        let (bounded, batches) = try await Self.render(sprite)
        #expect(bounded.count == 4)
        #expect(batches.batches[1]?.range == 0..<1)
    }

    @Test("Expanded sprites preserve offsets and painter order around non-sprite items")
    func expandedSpritesRespectBatchBoundaries() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()
        var first = Self.extractedSprite(id: 1, texture: .whiteTexture)
        first.size = Size(width: 3, height: 1)
        first.imageMode = .tiled()
        let second = Self.extractedSprite(id: 3, texture: .whiteTexture)
        let pipeline = try Self.makePipeline()
        let world = try Self.makeRenderWorld(extractedSprites: [1: first, 3: second], items: [
            Self.item(entity: 1, drawPass: SpriteDrawPass(), renderPipeline: pipeline, sortKey: 0, batchRange: 0..<0),
            Self.item(entity: 2, drawPass: TextDrawPass(), renderPipeline: pipeline, sortKey: 1, batchRange: 0..<0),
            Self.item(entity: 3, drawPass: SpriteDrawPass(), renderPipeline: pipeline, sortKey: 2, batchRange: 0..<0)
        ])
        await world.runScheduler(.update)
        let batches = try #require(world.getResource(SpriteBatches.self))
        #expect(batches.batches[1]?.range == 0..<3)
        #expect(batches.batches[3]?.range == 3..<4)
        let indices = try #require(world.getResource(SpriteDrawData.self)?.indexBuffer.elements)
        #expect(Array(indices.suffix(6)) == [12, 13, 14, 14, 15, 12])
    }

    @Test("Repeated sprite IDs and other draw passes retain separate ordered draw ranges")
    func repeatedIDsRetainDrawRanges() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()
        let pipeline = try Self.makePipeline()
        let sprite = Self.extractedSprite(id: 1, texture: .whiteTexture)
        let world = try Self.makeRenderWorld(extractedSprites: [1: sprite], items: [
            Self.item(entity: 1, drawPass: SpriteDrawPass(), renderPipeline: pipeline, sortKey: 0, batchRange: 0..<0),
            Self.item(entity: 1, drawPass: TextDrawPass(), renderPipeline: pipeline, sortKey: 1, batchRange: 0..<0),
            Self.item(entity: 1, drawPass: SpriteDrawPass(), renderPipeline: pipeline, sortKey: 2, batchRange: 0..<0),
        ])
        await world.runScheduler(.update)
        let prepared = try #require(world.getResource(SortedRenderItems<Transparent2DRenderItem>.self))
        #expect(prepared.items.items[0].batchRange == 0..<1)
        #expect(prepared.items.items[1].batchRange == 0..<0)
        #expect(prepared.items.items[2].batchRange == 1..<2)
        let data = try #require(world.getResource(SpriteDrawData.self))
        #expect(!data.usesInstancing, "Headless capability fallback must keep the production CPU path.")
        #expect(data.vertexBuffer.count == 8)
    }

    private static func render(_ sprite: ExtractedSprite) async throws -> ([SpriteVertexData], SpriteBatches) {
        let pipeline = try makePipeline()
        let world = try makeRenderWorld(extractedSprites: [sprite.entityId: sprite], items: [
            item(entity: sprite.entityId, drawPass: SpriteDrawPass(), renderPipeline: pipeline, sortKey: 0, batchRange: 0..<0)
        ])
        await world.runScheduler(.update)
        let data = try #require(world.getResource(SpriteDrawData.self))
        let batches = try #require(world.getResource(SpriteBatches.self))
        return (data.vertexBuffer.elements, batches)
    }

    private static func extractedSprite(id: Entity.ID, texture: Texture2D) -> ExtractedSprite {
        ExtractedSprite(
            entityId: id,
            texture: texture,
            size: nil,
            flipX: false,
            flipY: false,
            tintColor: .white,
            transform: Transform(),
            worldTransform: Transform3D()
        )
    }

    private static func item(
        entity: Entity.ID,
        drawPass: any DrawPass,
        renderPipeline: RenderPipeline,
        sortKey: Float,
        batchRange: Range<Int32>
    ) -> Transparent2DRenderItem {
        Transparent2DRenderItem(
            entity: entity,
            drawPass: drawPass,
            renderPipeline: renderPipeline,
            sortKey: sortKey,
            batchRange: batchRange
        )
    }

    private static func makePipeline() throws -> RenderPipeline {
        var pipelines = RenderPipelines(configurator: SpriteRenderPipeline())
        return pipelines.pipeline(device: unsafe RenderEngine.shared.renderDevice)
    }

    private static func makeRenderWorld(
        extractedSprites: [Entity.ID: ExtractedSprite],
        items: [Transparent2DRenderItem]
    ) throws -> World {
        let world = World()
        world
            .insertResource(ExtractedSprites(sprites: SparseSet(extractedSprites)))
            .insertResource(AdditionalExtractedSprites())
            .insertResource(SortedRenderItems(items: RenderItems(items: items)))
            .insertResource(SpriteDrawPass())
            .insertResource(SpriteBatches())
            .insertResource(SpriteDrawData.defaultValue)
            .insertResource(RenderPipelines(configurator: SpriteRenderPipeline()))
            .insertResource(RenderDeviceHandler(renderDevice: unsafe RenderEngine.shared.renderDevice))
            .addSystem(SpriteRenderSystem.self, on: .update)
        return world
    }

    private static func setupHeadlessRenderEngineIfNeeded() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }

        unsafe RenderEngine.configurations.preferredBackend = .headless
        try RenderEngine.setupRenderEngine()
    }
}
