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
