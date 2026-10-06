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

@Suite("Tile map chunks")
@MainActor
struct TileMapChunkTests {
    @Test("Negative cells use floor division and a cell edit preserves other chunk identities")
    func indexedDirtyChunks() async throws {
        let fixture = try makeFixture(cells: [[-33, 0], [-1, 0], [0, 0], [31, 0], [32, 0]])
        await update(fixture)
        let initial = try #require(fixture.owner.components[TileMapComponent.self]?.renderedChunks[fixture.layer.id])
        #expect(initial.count == 4)
        #expect(Set(initial.keys.map(\.x)) == [-2, -1, 0, 1])
        fixture.layer.setCellOrientation(.rotate90, at: [0, 0])
        await update(fixture)
        let changed = try #require(fixture.owner.components[TileMapComponent.self]?.renderedChunks[fixture.layer.id])
        for key in initial.keys {
            #expect((initial[key] === changed[key]) == (key.x != 0))
        }
        let revision = fixture.layer.updateRevision
        fixture.layer.setCell(at: [0, 0], sourceId: fixture.sourceID, atlasCoordinates: [0, 0], orientation: .rotate90)
        #expect(fixture.layer.updateRevision == revision)
        fixture.layer.removeCell(at: [-33, 0])
        await update(fixture)
        #expect(fixture.owner.components[TileMapComponent.self]?.renderedChunks[fixture.layer.id]?.count == 3)
    }

    @Test("Every shared map owner updates dirty chunks after another consumer clears the layer")
    func sharedOwners() async throws {
        let fixture = try makeFixture(cells: [[0, 0], [32, 0]])
        let second = fixture.main.spawn { TileMapComponent(tileMap: fixture.map, tileDisplaySize: Size(width: 1, height: 1)); Transform(position: [10, 0, 0]) }
        await update(fixture)
        let key = TileMapChunkCoordinate(cell: [32, 0])
        let firstOld = try #require(fixture.owner.components[TileMapComponent.self]?.renderedChunks[fixture.layer.id]?[key])
        let secondOld = try #require(second.components[TileMapComponent.self]?.renderedChunks[fixture.layer.id]?[key])
        fixture.layer.setCellOrientation(.mirrorX, at: [0, 0])
        await update(fixture)
        #expect(fixture.owner.components[TileMapComponent.self]?.renderedChunks[fixture.layer.id]?[key] === firstOld)
        #expect(second.components[TileMapComponent.self]?.renderedChunks[fixture.layer.id]?[key] === secondOld)
        let edited = try #require(second.components[TileMapComponent.self]?.renderedChunks[fixture.layer.id]?[TileMapChunkCoordinate(cell: [0, 0])])
        #expect(edited.atlasTiles.first?.transform.scale.x == -1)
    }

    @Test("Chunk culling is camera-specific and steady frames upload no static geometry")
    func cameraCullingAndCache() async throws {
        let fixture = try makeFixture(cells: [[0, 0], [64, 0]])
        await update(fixture)
        let render = try makeRenderWorld(main: fixture.main)
        let near = camera(in: render, owner: fixture.owner, left: -2, right: 2)
        let far = camera(in: render, owner: fixture.owner, left: 62, right: 66)
        await renderFrame(render)
        let draws = try #require(render.getResource(TileMapChunkRenderData.self))
        #expect(draws.visibleChunks == 2)
        #expect(draws.rebuiltChunks == 2)
        #expect(draws.instances.values.filter { $0.cameraID == near.id }.count == 1)
        #expect(draws.instances.values.filter { $0.cameraID == far.id }.count == 1)
        #expect(render.getResource(AdditionalExtractedSprites.self)?.sprites.isEmpty == true)
        await renderFrame(render)
        #expect(render.getResource(TileMapChunkRenderData.self)?.uploadedBytes == 0)
        #expect(render.getResource(TileMapChunkRenderData.self)?.rebuiltChunks == 0)
        fixture.layer.removeCell(at: [64, 0])
        await update(fixture)
        await renderFrame(render)
        #expect(render.getResource(TileMapChunkGPUCache.self)?.geometries.count == 1)
        #expect(render.getResource(TileMapChunkRenderData.self)?.visibleChunks == 1)
    }

    @Test("Parent translation/reflection affects chunk bounds without rebuilding geometry")
    func parentBoundsAndNoCulling() async throws {
        let fixture = try makeFixture(cells: [[64, 0]])
        await update(fixture)
        let render = try makeRenderWorld(main: fixture.main)
        _ = camera(in: render, owner: fixture.owner, left: -2, right: 2)
        await renderFrame(render)
        #expect(render.getResource(TileMapChunkRenderData.self)?.visibleChunks == 0)
        fixture.owner.components[Transform.self] = Transform(scale: [-1, 1, 1], position: [64, 0, 0])
        await fixture.main.runScheduler(.postUpdate)
        await renderFrame(render)
        #expect(render.getResource(TileMapChunkRenderData.self)?.visibleChunks == 1)
        fixture.owner.components[Transform.self]?.position = [1_000, 0, 0]
        fixture.owner.components += NoFrustumCulling()
        await fixture.main.runScheduler(.postUpdate)
        await renderFrame(render)
        #expect(render.getResource(TileMapChunkRenderData.self)?.visibleChunks == 1)
        #expect(render.getResource(TileMapChunkRenderData.self)?.rebuiltChunks == 0)
    }

    @Test("Static edits in another chunk retain entity-tile roots and their gameplay components")
    func entityTilesRemainIndependent() async throws {
        let fixture = try makeFixture(cells: [[0, 0]])
        let source = TileEntityAtlasSource()
        source.createTile(at: [0, 0], for: Entity { Sprite(); Transform(); LightOccluder2D(points: [[0, 0], [1, 0], [0, 1]]) })
        let sourceID = fixture.map.tileSet.addTileSource(source)
        fixture.layer.setCell(at: [64, 0], sourceId: sourceID, atlasCoordinates: [0, 0])
        await update(fixture)
        let rootID = try #require(fixture.owner.components[TileMapComponent.self]?.tileLayers[fixture.layer.id])
        let child = try #require(fixture.main.getEntityByID(rootID)?.children.first)
        fixture.layer.setCellOrientation(.rotate180, at: [0, 0])
        await update(fixture)
        #expect(fixture.owner.components[TileMapComponent.self]?.tileLayers[fixture.layer.id] == rootID)
        #expect(fixture.main.getEntityByID(child.id) != nil)
        #expect(child.components[LightOccluder2D.self]?.points.count == 3)
    }

    @Test("Animated tiles and tilted layers retain individual sprite extraction")
    func dynamicAndTiltFallback() async throws {
        let fixture = try makeFixture(cells: [[0, 0]])
        let animationSource = TextureAtlasTileSource(from: Image(width: 2, height: 1, color: .white), size: [1, 1])
        animationSource.createTile(for: [0, 0]).setAnimationFrameColumns(2)
        let animationID = fixture.map.tileSet.addTileSource(animationSource)
        fixture.layer.setCell(at: [1, 0], sourceId: animationID, atlasCoordinates: [0, 0])
        await update(fixture)
        let render = try makeRenderWorld(main: fixture.main)
        _ = camera(in: render, owner: fixture.owner, left: -2, right: 2)
        await renderFrame(render)
        #expect(render.getResource(AdditionalExtractedSprites.self)?.sprites.count == 1)
        #expect(render.getResource(ExtractedTileMapChunks.self)?.chunks.count == 1)
        fixture.owner.components[Transform.self]?.rotation = Quat(axis: [1, 0, 0], angle: .pi / 4)
        await fixture.main.runScheduler(.postUpdate)
        await renderFrame(render)
        #expect(render.getResource(AdditionalExtractedSprites.self)?.sprites.count == 2)
        #expect(render.getResource(ExtractedTileMapChunks.self)?.chunks.isEmpty == true)
    }

    @Test("Layer depths interleave chunks with ordinary sprites in painter order")
    func painterOrder() async throws {
        let fixture = try makeFixture(cells: [[0, 0]])
        let upper = fixture.map.createLayer()
        upper.zIndex = 2
        upper.setCell(at: [0, 0], sourceId: fixture.sourceID, atlasCoordinates: [0, 0])
        let sprite = fixture.main.spawn { Sprite(size: Size(width: 1, height: 1)); Transform(position: [0, 0, 1]) }
        await update(fixture)
        let render = try makeRenderWorld(main: fixture.main)
        let view = camera(in: render, owner: fixture.owner, left: -2, right: 2)
        view.components[VisibleEntities.self]?.entityIds.insert(sprite.id)
        await renderFrame(render)
        let items = try #require(render.getResource(SortedRenderItems<Transparent2DRenderItem>.self)?.items.items)
        #expect(items.map(\.sortKey) == [0, 1, 2])
        #expect(items[1].entity == sprite.id)
    }

    @Test("Atlas occluders remain chunked; exceptions invalidate one chunk and world geometry is cached")
    func atlasOcclusionCache() async throws {
        let fixture = try makeFixture(cells: [[-1, 0], [0, 0], [32, 0]])
        let source = try #require(fixture.map.tileSet.sources[fixture.sourceID] as? TextureAtlasTileSource)
        let polygon: [Vector2] = [[-8, -8], [8, -8], [8, 8], [-8, 8]]
        try source.setOccluderPolygon(polygon, at: [0, 0], referenceSize: [16, 16])
        await update(fixture)
        let original = try #require(fixture.owner.components[TileMapComponent.self]?.renderedChunks[fixture.layer.id])
        #expect(original.values.reduce(0) { $0 + $1.atlasTiles.count } == 3)
        #expect(original.values.allSatisfy { $0.entityCells.isEmpty && $0.occluderPolygons.count == 1 })
        #expect(fixture.owner.children.isEmpty)
        #expect(original[TileMapChunkCoordinate(cell: [0, 0])]?.occluderPolygons.first == [[-0.5, -0.5], [0.5, -0.5], [0.5, 0.5], [-0.5, 0.5]])
        let render = try makeRenderWorld(main: fixture.main)
        render.insertResource(ExtractedLighting2D())
        render.addSystem(ExtractLighting2DSystem.self, on: .extract)
        render.addSystem(ExtractTileMapOccludersSystem.self, on: .extract)
        await renderFrame(render)
        #expect(render.getResource(ExtractedLighting2D.self)?.occluders.count == 3)
        #expect(render.getResource(TileMapOcclusionCache.self)?.rebuiltChunks == 3)
        await renderFrame(render)
        #expect(render.getResource(ExtractedLighting2D.self)?.occluders.count == 3)
        #expect(render.getResource(TileMapOcclusionCache.self)?.rebuiltChunks == 0)
        fixture.layer.setCellOcclusion(.disabled, at: [0, 0])
        await update(fixture)
        let changed = try #require(fixture.owner.components[TileMapComponent.self]?.renderedChunks[fixture.layer.id])
        #expect(original[TileMapChunkCoordinate(cell: [-1, 0])] === changed[TileMapChunkCoordinate(cell: [-1, 0])])
        #expect(original[TileMapChunkCoordinate(cell: [32, 0])] === changed[TileMapChunkCoordinate(cell: [32, 0])])
        #expect(changed[TileMapChunkCoordinate(cell: [0, 0])]?.occluderPolygons.isEmpty == true)
        await renderFrame(render)
        #expect(render.getResource(ExtractedLighting2D.self)?.occluders.count == 2)
        #expect(render.getResource(TileMapOcclusionCache.self)?.geometries.count == 2)
        fixture.layer.setCellOcclusion(nil, at: [0, 0])
        fixture.layer.setCellOrientation(.mirrorXRotate90, at: [0, 0])
        fixture.owner.components[Transform.self] = Transform(scale: [-2, 3, 1], position: [10, 20, 0])
        await update(fixture)
        await renderFrame(render)
        let rings = try #require(render.getResource(ExtractedLighting2D.self)?.occluders)
        #expect(rings.count == 3)
        for ring in rings {
            let a = ring.worldPointsCCW[1] - ring.worldPointsCCW[0]
            let b = ring.worldPointsCCW[2] - ring.worldPointsCCW[0]
            #expect(a.x * b.y - a.y * b.x > 0)
        }
        #expect(render.getResource(TileMapOcclusionCache.self)?.rebuiltChunks == 3)
        fixture.owner.components[Visibility.self] = .hidden
        await renderFrame(render)
        #expect(render.getResource(ExtractedLighting2D.self)?.occluders.isEmpty == true)
        #expect(render.getResource(TileMapOcclusionCache.self)?.geometries.isEmpty == true)
    }

    @Test("The tile map plugin initializes the lighting bridge even without the lighting plugin")
    func occlusionPluginLifecycle() throws {
        let fixture = try makeFixture(cells: [[0, 0]])
        let app = AppWorlds(main: fixture.main)
        RenderWorldPlugin().setup(in: app)
        TileMapPlugin().setup(in: app)
        let render = try #require(app.getSubworldBuilder(by: .renderWorld)?.main)
        #expect(render.getResource(ExtractedLighting2D.self) != nil)
        #expect(render.getResource(TileMapOcclusionCache.self) != nil)
    }

    @Test("Custom cell polygons scale and shared owners/layer removal retain independent occlusion")
    func customOcclusionAndSharedOwners() async throws {
        let fixture = try makeFixture(cells: [[0, 0]])
        let custom = try TileOcclusionOverride.polygon([[-2, -1], [2, -1], [0, 1]], referenceSize: [4, 2])
        fixture.layer.setCellOcclusion(custom, at: [0, 0])
        let second = fixture.main.spawn {
            TileMapComponent(tileMap: fixture.map, tileDisplaySize: [2, 4])
            Transform(position: [100, 0, 0])
        }
        await update(fixture)
        let render = try makeRenderWorld(main: fixture.main)
        render.insertResource(ExtractedLighting2D())
        render.addSystem(ExtractLighting2DSystem.self, on: .extract)
        render.addSystem(ExtractTileMapOccludersSystem.self, on: .extract)
        await renderFrame(render)
        let rings = try #require(render.getResource(ExtractedLighting2D.self)?.occluders)
        #expect(rings.contains { $0.worldPointsCCW == [[-0.5, -0.5], [0.5, -0.5], [0, 0.5]] })
        #expect(rings.contains { $0.worldPointsCCW == [[99, -2], [101, -2], [100, 2]] })
        second.components[Visibility.self] = .hidden
        fixture.layer.isEnabled = false
        await update(fixture)
        await renderFrame(render)
        #expect(render.getResource(ExtractedLighting2D.self)?.occluders.isEmpty == true)
        fixture.layer.isEnabled = true
        fixture.layer.removeCell(at: [0, 0])
        await update(fixture)
        await renderFrame(render)
        #expect(render.getResource(TileMapOcclusionCache.self)?.geometries.isEmpty == true)
        #expect(fixture.layer.getCellOcclusion(at: [0, 0]) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_TILE_CHUNK_BENCHMARK"] == "1"))
    func largeMapBenchmark() async throws {
        var cells: [PointInt] = []
        for y in -128..<128 { for x in -128..<128 { cells.append([x, y]) } }
        let fixture = try makeFixture(cells: cells)
        await update(fixture)
        let render = try makeRenderWorld(main: fixture.main)
        _ = camera(in: render, owner: fixture.owner, left: -8, right: 8)
        let clock = ContinuousClock()
        for mode in [TileMapRenderMode.sprites, .chunks] {
            fixture.owner.components[TileMapComponent.self]?.renderMode = mode
            await renderFrame(render)
            let start = clock.now
            for _ in 0..<8 { await renderFrame(render) }
            let seconds = start.duration(to: clock.now).components
            let averageMS = (Double(seconds.seconds) + Double(seconds.attoseconds) / 1e18) * 1_000 / 8
            let draw = try #require(render.getResource(TileMapChunkRenderData.self))
            let spriteData = try #require(render.getResource(SpriteDrawData.self))
            let metric = "TileChunkBenchmark mode=\(mode.rawValue) cells=65536 averageMS=\(averageMS)"
                + " renderItems=\(render.getResource(SortedRenderItems<Transparent2DRenderItem>.self)?.items.items.count ?? 0)"
                + " spriteVertices=\(spriteData.vertexBuffer.count)"
                + " chunkDraws=\(draw.visibleChunks) staticUploadBytes=\(draw.uploadedBytes)"
            print(metric)
        }
        let old = try #require(fixture.owner.components[TileMapComponent.self]?.renderedChunks[fixture.layer.id])
        fixture.layer.setCellOrientation(.rotate90, at: [0, 0])
        await update(fixture)
        let new = try #require(fixture.owner.components[TileMapComponent.self]?.renderedChunks[fixture.layer.id])
        #expect(old.keys.filter { old[$0] !== new[$0] }.count == 1)
    }

    private struct Fixture {
        let main: World
        let map: TileMap
        let layer: TileMapLayer
        let sourceID: Int
        let owner: Entity
    }

    private func makeFixture(cells: [PointInt]) throws -> Fixture {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        TileMapComponent.registerComponent()
        Sprite.registerComponent()
        Transform.registerComponent()
        GlobalTransform.registerComponent()
        RelationshipComponent.registerComponent()
        Visibility.registerComponent()
        BoundingComponent.registerComponent()
        NoFrustumCulling.registerComponent()
        LightOccluder2D.registerComponent()
        Camera.registerComponent()
        VisibleEntities.registerComponent()
        let main = World()
        main.addSystem(TileMapSystem.self, on: .update)
        main.addSystem(TransformSystem.self, on: .postUpdate)
        main.addSystem(ChildTransformSystem.self, on: .postUpdate)
        let map = TileMap()
        let source = TextureAtlasTileSource(from: Image(width: 1, height: 1, color: .white), size: [1, 1])
        source.createTile(for: [0, 0])
        let sourceID = map.tileSet.addTileSource(source)
        let layer = try #require(map.layers.first)
        for cell in cells { layer.setCell(at: cell, sourceId: sourceID, atlasCoordinates: [0, 0]) }
        let owner = main.spawn { TileMapComponent(tileMap: map, tileDisplaySize: Size(width: 1, height: 1)); Transform() }
        return Fixture(main: main, map: map, layer: layer, sourceID: sourceID, owner: owner)
    }

    private func update(_ fixture: Fixture) async {
        await fixture.main.runScheduler(.update)
        await fixture.main.runScheduler(.postUpdate)
    }

    private func makeRenderWorld(main: World) throws -> World {
        let world = World()
        world.insertResource(MainWorld(world: main))
        world.insertResource(ExtractedSprites())
        world.insertResource(AdditionalExtractedSprites())
        world.insertResource(ExtractedTileMapChunks())
        world.insertResource(TileMapChunkGPUCache())
        world.insertResource(TileMapChunkRenderData())
        world.insertResource(RenderPipelines(configurator: TileMapChunkPipeline(from: world)))
        world.insertResource(RenderPipelines(configurator: SpriteRenderPipeline()))
        world.insertResource(RenderDeviceHandler(renderDevice: unsafe RenderEngine.shared.renderDevice))
        world.insertResource(SpriteDrawPass())
        world.insertResource(SpriteBatches())
        world.insertResource(SpriteDrawData.defaultValue)
        world.insertResource(RenderItems<Transparent2DRenderItem>())
        world.insertResource(SortedRenderItems<Transparent2DRenderItem>())
        world.addSystem(ClearTransparent2dRenderItemsSystem.self, on: .extract)
        world.addSystem(ExtractTileMapSpritesSystem.self, on: .extract)
        world.addSystem(ExtractSpriteSystem.self, on: .extract)
        world.addSystem(PrepareSpritesSystem.self, on: .preUpdate)
        world.addSystem(PrepareTileMapChunksSystem.self, on: .preUpdate)
        world.addSystem(Transparent2DBatchingSystem.self, on: .batching)
        world.addSystem(SpriteRenderSystem.self, on: .update)
        return world
    }

    private func camera(in world: World, owner: Entity, left: Float, right: Float) -> Entity {
        var camera = Camera()
        camera.computedData.frustum = Frustum.make(from: Transform3D.orthographic(left: left, right: right, top: 2, bottom: -2, zNear: -10, zFar: 10))
        return world.spawn { camera; VisibleEntities(entityIds: [owner.id]) }
    }

    private func renderFrame(_ world: World) async {
        await world.runScheduler(.extract)
        await world.runScheduler(.preUpdate)
        await world.runScheduler(.batching)
        await world.runScheduler(.update)
    }
}
