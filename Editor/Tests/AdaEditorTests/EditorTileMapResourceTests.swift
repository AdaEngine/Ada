@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorTileMapResourceTests {
    @Test("TileMap asset decoder reads painted palette files")
    func assetDecoderLoadsMap() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TileMapAssetTests")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Painted.tilemap")
        try EditorTileMapResource(atlasColors: [.red], cells: [[2, 3, 0]]).write(to: url)
        let handle = try await AssetsManager.load(TileMap.self, at: url.path)
        let map = try #require(handle.asset)
        #expect(map.layers.count == 1)
        #expect(map.layers[0].getCellTileSource(at: [2, 3]) == 0)
    }

    @Test("Painting a map persists cells and resolves the scene reference")
    func paintAndLoad() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TileMapResourceTests")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let maps = root.appendingPathComponent("Maps")
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = maps.appendingPathComponent("Painted.tilemap")
        try EditorTileMapResource(atlasColors: [.red, .blue], cells: []).write(to: url)
        let document = EditorAssetDocument(
            id: "asset:Maps/Painted.tilemap", title: "Painted.tilemap", relativePath: "Maps/Painted.tilemap",
            absolutePath: url.path, assetReference: "@res://Maps/Painted.tilemap", kind: .tileMap,
            fileExtension: "tilemap", byteCount: nil, modifiedAt: nil, errorMessage: nil
        )
        var saveCount = 0
        let painter = EditorTileMapEditorModel(document: document, onSave: { saveCount += 1 })
        let container = UIContainerView(rootView: EditorTileMapAssetEditor(document: document, model: painter))
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let canvas = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileMapEditor.Canvas"))
        #expect(canvas.absoluteFrame.width > 600)
        #expect(canvas.absoluteFrame.height > 500)
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileMapEditor.Color.1"))
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileMapEditor.Fit"))
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileMapEditor.LinkTileSet"))
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileMapEditor.NewTileSet"))
        let viewport = Size(width: 700, height: 600)
        painter.selectedColor = 1
        painter.paint(at: Point(350, 300), in: viewport)
        painter.endStroke()
        let reloaded = try EditorTileMapResource.read(from: url)
        #expect(reloaded.cells == [[0, 0, 1]])
        #expect(saveCount == 1)
        painter.tool = .erase
        painter.paint(at: Point(350, 300), in: viewport)
        painter.endStroke()
        #expect(try EditorTileMapResource.read(from: url).cells.isEmpty)
        #expect(saveCount == 2)
        painter.tool = .pan
        painter.pan(by: Size(width: -24_000, height: 0))
        painter.endPan()
        painter.tool = .paint
        painter.paint(at: Point(350, 300), in: viewport)
        painter.endStroke()
        #expect(try EditorTileMapResource.read(from: url).cells == [[1_000, 0, 1]])
        painter.fitMap(in: viewport)
        #expect(painter.cell(at: Point(350, 300), in: viewport).x == 1_000)
        let tile = painter.tileRect(atX: 1_001, y: 2, in: viewport)
        #expect(tile.midX > viewport.width / 2)
        #expect(tile.midY < viewport.height / 2)
        #expect(painter.cell(at: Point(tile.midX, tile.midY), in: viewport).x == 1_001)
        #expect(painter.cell(at: Point(tile.midX, tile.midY), in: viewport).y == 2)

        var scene = EditorSceneModel.default(projectName: "Painted")
        let entity = scene.addEntity(template: .tileMap, parentID: scene.rootEntityID)
        let index = try #require(scene.entities.firstIndex(where: { $0.id == entity.id }))
        scene.entities[index].components[EditorBuiltInComponentType.tileMap]?["map"] = .string("@res://Maps/Painted.tilemap")
        let world = World(name: "PaintedTileMap")
        let result = EditorSceneFileLoader.load(model: scene, into: world, loadsScriptableObjects: false, resourceRootURL: root)
        #expect(result.warnings.isEmpty, Comment(rawValue: result.warnings.joined(separator: "\n")))
        let entityID = try #require(result.entitiesByEditorID[entity.id])
        let map = try #require(world.get(TileMapComponent.self, from: entityID)?.tileMap)
        #expect(map.layers[0].getCellTileSource(at: [1_000, 0]) == 0)
    }

    @Test("Window pointer coordinates paint the intended tile and navigation events reach the canvas")
    func pointerNavigation() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TileMapPointerTests")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Pointer.tilemap")
        try EditorTileMapResource(atlasColors: [.red], cells: []).write(to: url)
        let document = EditorAssetDocument(
            id: "asset:Pointer.tilemap", title: "Pointer.tilemap", relativePath: "Pointer.tilemap",
            absolutePath: url.path, assetReference: "@res://Pointer.tilemap", kind: .tileMap,
            fileExtension: "tilemap", byteCount: nil, modifiedAt: nil, errorMessage: nil
        )
        var saveCount = 0
        let model = EditorTileMapEditorModel(document: document, onSave: { saveCount += 1 })
        let container = UIContainerView(rootView: HStack(spacing: 0) {
            Color.clear.frame(width: 180)
            EditorTileMapAssetEditor(document: document, model: model)
        })
        container.frame = Rect(x: 0, y: 0, width: 1_000, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let frame = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileMapEditor.Canvas")).absoluteFrame
        #expect(frame.minX >= 180)
        let pointer = Point(x: frame.midX + 36, y: frame.midY - 36)
        func mouse(
            _ phase: MouseEvent.Phase,
            at position: Point? = nil,
            button: MouseButton = .left,
            delta: Point = .zero,
            modifiers: KeyModifier = []
        ) {
            container.onMouseEvent(MouseEvent(
                window: .empty, button: button, scrollDelta: delta,
                mousePosition: position ?? pointer, phase: phase, modifierKeys: modifiers, time: 0
            ))
        }
        mouse(.began)
        mouse(.ended)
        #expect(try EditorTileMapResource.read(from: url).cells == [[2, 2, 0]])
        let adjacent = Point(x: pointer.x + 24, y: pointer.y)
        mouse(.began, at: adjacent)
        mouse(.ended, at: adjacent)
        #expect(saveCount == 2)
        mouse(.began, button: .right)
        mouse(.changed, at: adjacent, button: .right)
        mouse(.ended, at: adjacent, button: .right)
        #expect(try EditorTileMapResource.read(from: url).cells.isEmpty)
        #expect(saveCount == 3)
        #expect(model.tool == .paint)
        mouse(.began)
        mouse(.ended)
        #expect(try EditorTileMapResource.read(from: url).cells == [[2, 2, 0]])

        mouse(.changed, button: .scrollWheel, delta: Point(x: 1, y: 2))
        #expect(model.panOffset.x > 0)
        #expect(model.panOffset.y > 0)
        mouse(.changed, button: .scrollWheel, delta: Point(x: 0, y: 1), modifiers: [.main])
        #expect(model.zoom > 1)
        let zoomBeforePinch = model.zoom
        container.onReceiveEvent(PinchEvent(window: .empty, location: pointer, scale: 1, phase: .began, time: 0))
        container.onReceiveEvent(PinchEvent(window: .empty, location: pointer, scale: 1.25, phase: .changed, time: 0.01))
        container.onReceiveEvent(PinchEvent(window: .empty, location: pointer, scale: 1.25, phase: .ended, time: 0.02))
        #expect(model.zoom > zoomBeforePinch)
    }

    @Test("Tilemap preview uses the referenced scene's world tile size")
    func sceneTileSize() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TileMapSceneSizeTests")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let maps = root.appendingPathComponent("Maps")
        let scenes = root.appendingPathComponent("Scenes")
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scenes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mapURL = maps.appendingPathComponent("Arena.tilemap")
        try EditorTileMapResource(atlasColors: [.red], cells: [[2, 3, 0]]).write(to: mapURL)
        var scene = EditorSceneModel.default(projectName: "Arena")
        let entity = scene.addEntity(template: .tileMap, parentID: scene.rootEntityID)
        let index = try #require(scene.entities.firstIndex(where: { $0.id == entity.id }))
        scene.entities[index].components[EditorBuiltInComponentType.tileMap]?["map"] = .string("@res://Maps/Arena.tilemap")
        scene.entities[index].components[EditorBuiltInComponentType.tileMap]?["tileDisplaySize"] = .array([.int(48), .int(32)])
        try scene.encodedYAML().write(to: scenes.appendingPathComponent("Main.ascn"), atomically: true, encoding: .utf8)
        let document = EditorAssetDocument(
            id: "asset:Maps/Arena.tilemap", title: "Arena.tilemap", relativePath: "Maps/Arena.tilemap",
            absolutePath: mapURL.path, assetReference: "@res://Maps/Arena.tilemap", kind: .tileMap,
            fileExtension: "tilemap", byteCount: nil, modifiedAt: nil, errorMessage: nil
        )
        let model = EditorTileMapEditorModel(document: document)
        let viewport = Size(width: 800, height: 600)
        let rect = model.tileRect(atX: 2, y: 3, in: viewport)
        #expect(rect.width == 48)
        #expect(rect.height == 32)
        #expect(rect.midX == viewport.width / 2 + 2 * 48)
        #expect(rect.midY == viewport.height / 2 - 3 * 32)
        #expect(model.cell(at: Point(rect.midX, rect.midY), in: viewport).x == 2)
        #expect(model.cell(at: Point(rect.midX, rect.midY), in: viewport).y == 3)
    }

    @Test("Linking a Tile Source adds authored tiles without changing existing map cells")
    func linkedTileSource() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "LinkedTileSetTests")))
        }
        TextureAtlasTileSource.registerTileSource()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let maps = root.appendingPathComponent("Maps")
        let tiles = root.appendingPathComponent("Tiles")
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mapURL = maps.appendingPathComponent("Arena.tilemap")
        try EditorTileMapResource(atlasColors: [.red, .blue], cells: [[0, 0, 0]]).write(to: mapURL)
        let tileSetURL = tiles.appendingPathComponent("Arena.tileset")
        try Data("tileSize: {x: 16, y: 16}\nsources: []\n".utf8).write(to: tileSetURL)
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let wall = tiles.appendingPathComponent("wall.png")
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("Demos/MedievalArena/Assets/Tiles/tile_0014.png"), to: wall
        )
        let sourceDocument = EditorAssetDocument(
            id: "asset:Tiles/Arena.tileset", title: "Arena.tileset", relativePath: "Tiles/Arena.tileset",
            absolutePath: tileSetURL.path, assetReference: "@res://Tiles/Arena.tileset", kind: .tileSource,
            fileExtension: "tileset", byteCount: nil, modifiedAt: nil, errorMessage: nil
        )
        let sourceEditor = EditorTileSourceEditorModel(document: sourceDocument)
        sourceEditor.addImages([wall])
        sourceEditor.createAllTiles()
        #expect(sourceEditor.tiles.count == 1)

        let mapDocument = EditorAssetDocument(
            id: "asset:Maps/Arena.tilemap", title: "Arena.tilemap", relativePath: "Maps/Arena.tilemap",
            absolutePath: mapURL.path, assetReference: "@res://Maps/Arena.tilemap", kind: .tileMap,
            fileExtension: "tilemap", byteCount: nil, modifiedAt: nil, errorMessage: nil
        )
        let editor = EditorTileMapEditorModel(document: mapDocument)
        editor.linkTileSet(at: tileSetURL)
        #expect(editor.map.tileSetReference == "@res://Tiles/Arena.tileset")
        #expect(editor.paletteCount == 3)
        #expect(editor.image(at: 2) != nil)
        let container = UIContainerView(rootView: EditorTileMapAssetEditor(document: mapDocument, model: editor))
        container.frame = Rect(x: 0, y: 0, width: 1_000, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileMapEditor.Color.2"))
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileMapEditor.RefreshTileSet"))
        editor.selectedColor = 2
        editor.paint(at: Point(374, 300), in: Size(width: 700, height: 600))
        editor.endStroke()
        let saved = try EditorTileMapResource.read(from: mapURL)
        #expect(saved.cells.contains([0, 0, 0]))
        #expect(saved.cells.contains([1, 0, 2]))

        let floor = tiles.appendingPathComponent("floor.png")
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("Demos/MedievalArena/Assets/Tiles/tile_0000.png"), to: floor
        )
        sourceEditor.addImages([floor])
        sourceEditor.createAllTiles()
        editor.refreshTileSet()
        #expect(editor.paletteCount == 4)
        #expect(try EditorTileMapResource.read(from: mapURL).cells.contains([1, 0, 2]))

        var scene = EditorSceneModel.default(projectName: "Linked Arena")
        let entity = scene.addEntity(template: .tileMap, parentID: scene.rootEntityID)
        let index = try #require(scene.entities.firstIndex(where: { $0.id == entity.id }))
        scene.entities[index].components[EditorBuiltInComponentType.tileMap]?["map"] = .string("@res://Maps/Arena.tilemap")
        let world = World(name: "LinkedArenaScene")
        let result = EditorSceneFileLoader.load(model: scene, into: world, loadsScriptableObjects: false, resourceRootURL: root)
        #expect(result.warnings.isEmpty, Comment(rawValue: result.warnings.joined(separator: "\n")))
        let entityID = try #require(result.entitiesByEditorID[entity.id])
        let loaded = try #require(world.get(TileMapComponent.self, from: entityID)?.tileMap)
        #expect(loaded.layers[0].getCellTileSource(at: [0, 0]) == 0)
        #expect(loaded.layers[0].getCellTileSource(at: [1, 0]) == 1)
    }

    @Test("A map can create and link an empty Tile Source for PNG authoring")
    func createTileSource() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "NewTileSetTests")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let maps = root.appendingPathComponent("Maps")
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mapURL = maps.appendingPathComponent("Arena.tilemap")
        try EditorTileMapResource(atlasColors: [.red], cells: [[0, 0, 0]]).write(to: mapURL)
        let document = EditorAssetDocument(
            id: "asset:Maps/Arena.tilemap", title: "Arena.tilemap", relativePath: "Maps/Arena.tilemap",
            absolutePath: mapURL.path, assetReference: "@res://Maps/Arena.tilemap", kind: .tileMap,
            fileExtension: "tilemap", byteCount: nil, modifiedAt: nil, errorMessage: nil
        )
        let editor = EditorTileMapEditorModel(document: document)
        editor.createTileSet()
        let tileSetURL = root.appendingPathComponent("Tiles/Arena.tileset")
        #expect(FileManager.default.fileExists(atPath: tileSetURL.path))
        #expect(editor.map.tileSetReference == "@res://Tiles/Arena.tileset")
        #expect(editor.map.cells == [[0, 0, 0]])
        let tileSetDocument = EditorAssetDocument(
            id: "asset:Tiles/Arena.tileset", title: "Arena.tileset", relativePath: "Tiles/Arena.tileset",
            absolutePath: tileSetURL.path, assetReference: "@res://Tiles/Arena.tileset", kind: .tileSource,
            fileExtension: "tileset", byteCount: nil, modifiedAt: nil, errorMessage: nil
        )
        #expect(EditorTileSourceEditorModel(document: tileSetDocument).isEditable)
    }
}
