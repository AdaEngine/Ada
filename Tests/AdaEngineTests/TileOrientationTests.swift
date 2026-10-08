@_spi(Internal) import AdaApp
@_spi(Internal) import AdaAssets
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaSprite
@testable import AdaTilemap
import AdaTransform
import Foundation
import Math
import Testing

@Suite("Tile orientation")
@MainActor
struct TileOrientationTests {
    @Test("Atlas and entity tiles share the same rectangular-cell transform", arguments: TileOrientation.allCases)
    func orientedGeometry(orientation: TileOrientation) async throws {
        try setupRenderer()
        let map = TileMap()
        let atlas = TextureAtlasTileSource(from: Image(width: 2, height: 3, color: .white), size: [2, 3])
        atlas.createTile(for: [0, 0])
        let atlasID = map.tileSet.addTileSource(atlas)
        let entities = TileEntityAtlasSource()
        let ring: [Vector2] = [[-1, -1.5], [1, -1.5], [0, 1.5]]
        entities.createTile(at: [0, 0], for: Entity {
            Sprite()
            Transform()
            LightOccluder2D(points: ring)
        })
        let entityID = map.tileSet.addTileSource(entities)
        let layer = try #require(map.layers.first)
        layer.setCell(at: [0, 0], sourceId: atlasID, atlasCoordinates: [0, 0], orientation: orientation)
        layer.setCell(at: [1, 0], sourceId: entityID, atlasCoordinates: [0, 0], orientation: orientation)
        let world = makeWorld()
        let owner = world.spawn {
            TileMapComponent(tileMap: map, tileDisplaySize: Size(width: 2, height: 3))
            Transform(position: [10, 20, 0])
        }
        await world.runScheduler(.update)
        await world.runScheduler(.postUpdate)

        let component = try #require(owner.components[TileMapComponent.self])
        let tile = try #require(component.renderedAtlasTiles[layer.id]?.first)
        let child = try #require(owner.children.first?.children.first)
        let entityTransform = try #require(child.components[Transform.self])
        let occluder = try #require(child.components[LightOccluder2D.self])
        #expect(occluder.points == ring)

        // Reference results for the original bottom-left corner; no implementation helper is used.
        let expected: [Vector2] = [
            [-1, -1.5], [1, -1.5], [1, 1.5], [-1, 1.5],
            [1, -1.5], [1, 1.5], [-1, 1.5], [-1, -1.5]
        ]
        let actual = tile.transform.matrix * Vector4(-1, -1.5, 0, 1)
        #expect(abs(actual.x - expected[orientation.rawValue].x) < 0.0001)
        #expect(abs(actual.y - expected[orientation.rawValue].y) < 0.0001)
        let entityCorner = entityTransform.matrix * Vector4(occluder.points[0].x, occluder.points[0].y, 0, 1)
        #expect(abs(entityCorner.x - (actual.x + 2)) < 0.0001)
        #expect(abs(entityCorner.y - actual.y) < 0.0001)
        let worldCorner = try #require(child.components[GlobalTransform.self]).matrix * Vector4(-1, -1.5, 0, 1)
        #expect(abs(worldCorner.x - (actual.x + 12)) < 0.0001)
        #expect(abs(worldCorner.y - (actual.y + 20)) < 0.0001)

        let renderWorld = World()
        renderWorld.insertResource(MainWorld(world: world))
        renderWorld.insertResource(ExtractedLighting2D())
        renderWorld.addSystem(ExtractLighting2DSystem.self, on: .extract)
        await renderWorld.runScheduler(.extract)
        let extractedRing = try #require(renderWorld.getResource(ExtractedLighting2D.self)?.occluders.first?.worldPointsCCW)
        #expect(extractedRing.count == 3)
        let firstEdge = extractedRing[1] - extractedRing[0]
        let secondEdge = extractedRing[2] - extractedRing[0]
        #expect(firstEdge.x * secondEdge.y - firstEdge.y * secondEdge.x > 0)
    }

    @Test("Orientation edits rebuild all owners of a shared map")
    func sharedOwnersUpdate() async throws {
        try setupRenderer()
        let map = TileMap()
        let source = TextureAtlasTileSource(from: Image(width: 2, height: 3, color: .white), size: [2, 3])
        source.createTile(for: [0, 0])
        let sourceID = map.tileSet.addTileSource(source)
        let layer = try #require(map.layers.first)
        layer.setCell(at: [0, 0], sourceId: sourceID, atlasCoordinates: [0, 0])
        let world = makeWorld()
        let owners = (0..<2).map { _ in
            world.spawn {
                TileMapComponent(tileMap: map, tileDisplaySize: Size(width: 2, height: 3))
                Transform()
            }
        }
        await world.runScheduler(.update)
        layer.setCellOrientation(.mirrorXRotate90, at: [0, 0])
        #expect(map.needsUpdate)
        await world.runScheduler(.update)
        for owner in owners {
            let tile = try #require(owner.components[TileMapComponent.self]?.renderedAtlasTiles[layer.id]?.first)
            let corner = tile.transform.matrix * Vector4(-1, -1.5, 0, 1)
            #expect(abs(corner.x - 1) < 0.0001)
            #expect(abs(corner.y - 1.5) < 0.0001)
        }
        let revision = layer.updateRevision
        layer.setCellOrientation(.mirrorXRotate90, at: [0, 0])
        layer.setCellOrientation(.rotate90, at: [999, 999])
        #expect(layer.updateRevision == revision)
    }

    @Test("Native tile resources round-trip orientation and load legacy identity")
    func resourceRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TileOrientation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let map = TileMap()
        for orientation in TileOrientation.allCases {
            map.setCell(for: 0, coordinates: [orientation.rawValue, 0], sourceId: 0, atlasCoordinates: [0, 0], orientation: orientation)
        }
        let path = directory.appendingPathComponent("orientations.tilemap").path
        let scopeID = UUID()
        try await AppWorldsExecutionContext.$currentID.withValue(scopeID) {
            try await AssetsManager.save(map, at: path)
            let loaded = try #require(try await AssetsManager.load(TileMap.self, at: path).asset)
            for orientation in TileOrientation.allCases {
                #expect(loaded.layers[0].getCellOrientation(at: [orientation.rawValue, 0]) == orientation)
            }
            let legacyPath = directory.appendingPathComponent("legacy.tilemap")
            try Data(#"{"layers":[{"name":"Legacy","id":0,"tiles":[{"p":[0,0],"ap":[0,0],"sid":0}]}]}"#.utf8).write(to: legacyPath)
            let legacy = try #require(try await AssetsManager.load(TileMap.self, at: legacyPath.path).asset)
            #expect(legacy.layers[0].getCellOrientation(at: [0, 0]) == .identity)
        }
        await AssetsManager.destroyScope(scopeID)
    }

    @Test("Portable image palettes accept an optional fourth orientation value")
    func portablePaletteOrientation() throws {
        try setupRenderer()
        let map = TileMap()
        try map.setImagePalette([Image(width: 2, height: 3, color: .white)], cells: [[0, 0, 0], [1, 0, 0, 6]])
        #expect(map.layers[0].getCellOrientation(at: [0, 0]) == .identity)
        #expect(map.layers[0].getCellOrientation(at: [1, 0]) == .mirrorXRotate180)
        #expect(throws: AssetDecodingError.self) {
            try TileMap().setImagePalette([Image(width: 2, height: 3, color: .white)], cells: [[0, 0, 0, 8]])
        }
    }

    private func makeWorld() -> World {
        TileMapComponent.registerComponent()
        TileEntityAtlasSource.registerTileSource()
        RelationshipComponent.registerComponent()
        Transform.registerComponent()
        GlobalTransform.registerComponent()
        Sprite.registerComponent()
        LightOccluder2D.registerComponent()
        Light2D.registerComponent()
        LightModulate2D.registerComponent()
        Visibility.registerComponent()
        BoundingComponent.registerComponent()
        let world = World()
        world.addSystem(TileMapSystem.self, on: .update)
        world.addSystem(TransformSystem.self, on: .postUpdate)
        world.addSystem(ChildTransformSystem.self, on: .postUpdate)
        return world
    }

    private func setupRenderer() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }
        unsafe RenderEngine.configurations.preferredBackend = .headless
        try RenderEngine.setupRenderEngine()
    }
}
