@_spi(AdaEngine) import AdaEngine
@testable import AdaTilemap
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor tile occlusion", .serialized)
@MainActor
struct EditorTileOcclusionTests {
    @Test("Visual tileset authoring persists polygons and the runtime retains chunk rendering")
    func tilesetAuthoring() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.source
        model.displayWidth = "0" // An unapplied slicing-field draft must not change polygon coordinates.
        model.selectTile([0, 0])
        #expect(model.occlusionDraft.referenceSize == Size(width: 16, height: 16))
        let inspector = container(EditorTileSourceAssetEditor(document: fixture.sourceDocument, model: model).inspector, height: 1_800)
        _ = try inspector.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.TileSourceEditor.Occlusion.Rectangle"))
        let polygonNode = try inspector.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileSourceEditor.Occlusion.Canvas"))
        let frame = polygonNode.absoluteFrame
        let start = Point(frame.minX + 1, frame.maxY - 1)
        let end = Point(frame.minX + frame.width * 0.25, frame.minY + frame.height * 0.75)
        inspector.onMouseEvent(mouse(start, .began))
        inspector.onMouseEvent(mouse(end, .changed))
        inspector.onMouseEvent(mouse(end, .ended))
        #expect(abs(model.occlusionDraft.points[0].x + 4) < 0.01)
        #expect(abs(model.occlusionDraft.points[0].y + 4) < 0.01)
        _ = try inspector.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.TileSourceEditor.Occlusion.Apply"))
        let reopened = EditorTileSourceEditorModel(document: fixture.sourceDocument)
        reopened.selectTile([0, 0])
        #expect(reopened.occlusionDraft.points == model.occlusionDraft.points)
        #expect(reopened.occlusionDraft.referenceSize == Size(width: 16, height: 16))
        TextureAtlasTileSource.registerTileSource()
        let handle = try await AssetsManager.load(TileSet.self, at: fixture.sourceURL.path)
        let tileSet = try #require(handle.asset)
        let source = try #require(tileSet.sources[0] as? TextureAtlasTileSource)
        #expect(source.occluderPolygon(at: [0, 0]) == model.occlusionDraft.points)
        let map = TileMap()
        try map.installTileSetPalette(tileSet, palette: [TileMapSourceTile(sourceID: 0, atlasCoordinates: [0, 0])], cells: [[0, 0, 0]], firstPaletteIndex: 0)
        let world = World()
        world.addSystem(TileMapSystem.self)
        let owner = world.spawn { TileMapComponent(tileMap: map, tileDisplaySize: [32, 32]); Transform() }
        await world.runScheduler(.update)
        #expect(owner.children.isEmpty)
        let chunk = try #require(owner.components[TileMapComponent.self]?.renderedChunks[map.layers[0].id]?.values.first)
        #expect(chunk.atlasTiles.count == 1)
        #expect(chunk.occluderPolygons.first?.first == Vector2(-8, -8))
        let before = try Data(contentsOf: fixture.sourceURL)
        model.occlusionDraft.points = [[-8, -8], [8, 8], [-8, 8], [8, -8]]
        model.applyOcclusion()
        #expect(try Data(contentsOf: fixture.sourceURL) == before)
        model.occlusionDraft.clear()
        model.applyOcclusion()
        reopened.reload()
        reopened.selectTile([0, 0])
        #expect(reopened.occlusionDraft.points.isEmpty)
    }

    @Test("Cell selection, overrides, layer moves and painting survive save/reopen and scene loading")
    func cellAuthoring() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.source.selectTile([0, 0])
        fixture.source.occlusionDraft.rectangle()
        fixture.source.applyOcclusion()
        let mapURL = fixture.root.appendingPathComponent("Walls.tilemap")
        try EditorTileMapResource(atlasColors: [], cells: [[0, 0, 0]]).write(to: mapURL)
        let document = asset(mapURL, kind: .tileMap)
        let model = EditorTileMapEditorModel(document: document)
        model.linkTileSet(at: fixture.sourceURL)
        let viewport = container(EditorTileMapAssetEditor(document: document, model: model), width: 800, height: 600)
        _ = try viewport.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.TileMapEditor.Select"))
        let canvas = try viewport.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileMapEditor.Canvas"))
        let origin = model.canvasOrigin(in: canvas.absoluteFrame.size)
        let position = Point(canvas.absoluteFrame.minX + origin.x, canvas.absoluteFrame.minY + origin.y)
        viewport.onMouseEvent(mouse(position, .began))
        viewport.onMouseEvent(mouse(position, .ended))
        #expect(model.selectedCell == TileMapCoordinate(x: 0, y: 0))
        #expect(model.occlusionMode == "Inherit")
        #expect(model.occlusionDraft.points.count == 4)
        model.setOcclusionMode("Disabled")
        #expect(try EditorTileMapResource.read(from: mapURL).cellOcclusion?.first?.occlusion == .disabled)
        model.setOcclusionMode("Custom")
        model.occlusionDraft.points = [[-4, -4], [4, -4], [0, 4]]
        let inspector = container(EditorTileMapInspector(document: document, model: model), height: 1_200)
        _ = try inspector.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.TileMapEditor.Occlusion.Apply"))
        let expected = try TileOcclusionOverride.polygon([[-4, -4], [4, -4], [0, 4]], referenceSize: [16, 16])
        let reopened = EditorTileMapEditorModel(document: document)
        reopened.selectCell(at: reopened.canvasOrigin(in: [600, 400]), in: [600, 400])
        #expect(reopened.occlusionMode == "Custom")
        #expect(reopened.occlusionDraft.points == expected.points)
        model.addLayer()
        model.selectLayer(0)
        model.moveSelectedLayer(by: 1)
        #expect(model.layers[1].cellOcclusion?.first?.occlusion == expected)
        #expect(model.map.cellOcclusion == nil)
        var scene = EditorSceneModel.default(projectName: "Occlusion")
        let entity = scene.addEntity(template: .tileMap, parentID: scene.rootEntityID)
        let index = try #require(scene.entities.firstIndex { $0.id == entity.id })
        scene.entities[index].components[EditorBuiltInComponentType.tileMap]?["map"] = .string("@res://Walls.tilemap")
        let world = World()
        let result = EditorSceneFileLoader.load(model: scene, into: world, loadsScriptableObjects: false, resourceRootURL: fixture.root)
        #expect(result.warnings.isEmpty, Comment(rawValue: result.warnings.joined(separator: "\n")))
        let runtimeID = try #require(result.entitiesByEditorID[entity.id])
        let runtime = try #require(world.get(TileMapComponent.self, from: runtimeID)?.tileMap)
        #expect(runtime.layers[1].getCellOcclusion(at: [0, 0]) == expected)
        model.selectCell(at: model.canvasOrigin(in: [600, 400]), in: [600, 400])
        model.setOcclusionMode("Inherit")
        #expect(model.layers[1].cellOcclusion == nil)
        model.setOcclusionMode("Disabled")
        model.tool = .erase
        model.erase(at: model.canvasOrigin(in: [600, 400]), in: [600, 400])
        model.endStroke()
        #expect(model.layers[1].cells.isEmpty)
        #expect(model.layers[1].cellOcclusion?.isEmpty == true)
        #expect(model.selectedCell == nil)
    }

    @Test("Removing palette tiles prunes only overrides belonging to removed cells", arguments: [false, true])
    func paletteRemoval(layered: Bool) throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = fixture.root.appendingPathComponent("Colors.tilemap")
        let records = [
            TileMapCellOcclusion(position: [0, 0], occlusion: .disabled),
            TileMapCellOcclusion(position: [1, 0], occlusion: .disabled),
        ]
        var resource = EditorTileMapResource(atlasColors: [.red, .blue], cells: [[0, 0, 0], [1, 0, 1]])
        if layered {
            resource.paletteLayers = [.init(name: "Walls", zIndex: 0, isEnabled: true, cells: resource.cells, cellOcclusion: records)]
            resource.cells = []
        } else { resource.cellOcclusion = records }
        try resource.write(to: url)
        let model = EditorTileMapEditorModel(document: asset(url, kind: .tileMap))
        model.selectedColor = 0
        model.removeSelectedColor()
        let loaded = try EditorTileMapResource.read(from: url)
        #expect(loaded.effectiveLayers[0].cells == [[1, 0, 0]])
        #expect(loaded.effectiveLayers[0].cellOcclusion == [records[1]])
    }

    private func mouse(_ point: Point, _ phase: MouseEvent.Phase) -> MouseEvent {
        MouseEvent(window: .empty, button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0)
    }

    private func container<V: View>(_ view: V, width: Float = 360, height: Float) -> UIContainerView<V> {
        let container = UIContainerView(rootView: view)
        container.frame = Rect(x: 0, y: 0, width: width, height: height)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        return container
    }

    private func asset(_ url: URL, kind: EditorAssetPreviewKind) -> EditorAssetDocument {
        EditorAssetDocument(
            id: url.path,
            title: url.lastPathComponent,
            relativePath: url.lastPathComponent,
            absolutePath: url.path,
            assetReference: "@res://\(url.lastPathComponent)",
            kind: kind,
            fileExtension: url.pathExtension,
            byteCount: nil,
            modifiedAt: nil,
            errorMessage: nil
        )
    }

    private func fixture() throws -> Fixture {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World()))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TileOcclusionEditor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("Walls.tileset")
        try Data("tileSize: {x: 16, y: 16}\nsources: []\n".utf8).write(to: sourceURL)
        let png = root.appendingPathComponent("wall.png")
        try Image(width: 16, height: 16, color: .white).pngData().write(to: png)
        let document = asset(sourceURL, kind: .tileSource)
        let model = EditorTileSourceEditorModel(document: document)
        model.addImages([png])
        model.createAllTiles()
        return Fixture(root: root, sourceURL: sourceURL, sourceDocument: document, source: model)
    }

    private struct Fixture {
        let root: URL
        let sourceURL: URL
        let sourceDocument: EditorAssetDocument
        let source: EditorTileSourceEditorModel
    }
}
