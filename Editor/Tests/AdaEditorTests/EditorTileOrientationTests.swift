@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorTileOrientationTests {
    @Test("Brush orientations, same-tile repaint, selection and layered resource round trips")
    func paintAndReopen() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let model = fixture.model
        let size = Size(width: 700, height: 600)
        for orientation in TileOrientation.allCases {
            model.brushOrientation = orientation
            let rect = model.tileRect(atX: orientation.rawValue, y: -2, in: size)
            model.paint(at: Point(rect.midX, rect.midY), in: size)
            model.endStroke()
        }
        model.reload()
        for orientation in TileOrientation.allCases {
            #expect(model.orientation(at: .init(x: orientation.rawValue, y: -2), layer: 0) == orientation)
        }
        let rect = model.tileRect(atX: 1, y: -2, in: size)
        model.selectCell(at: Point(rect.midX, rect.midY), in: size)
        model.setSelectedCellOrientation(.mirrorXRotate270)
        #expect(model.selectedCellOrientation == .mirrorXRotate270)
        model.brushOrientation = .rotate180
        model.paint(at: Point(rect.midX, rect.midY), in: size)
        model.endStroke()
        #expect(model.selectedCellOrientation == .rotate180)
        model.addLayer()
        model.brushOrientation = .mirrorX
        model.paint(at: Point(rect.midX, rect.midY), in: size)
        model.endStroke()
        model.reload()
        #expect(model.orientation(at: .init(x: 1, y: -2), layer: 0) == .rotate180)
        #expect(model.orientation(at: .init(x: 1, y: -2), layer: 1) == .mirrorX)
        let map = try #require(try await AssetsManager.load(TileMap.self, at: fixture.url.path).asset)
        #expect(map.layers[0].getCellOrientation(at: [1, -2]) == .rotate180)
        #expect(map.layers[1].getCellOrientation(at: [1, -2]) == .mirrorX)
        model.erase(at: Point(rect.midX, rect.midY), in: size)
        model.endStroke()
        #expect(model.orientation(at: .init(x: 1, y: -2), layer: 1) == .identity)
    }

    @Test("Canvas uses all orientations for rectangular textured cells and keeps their centers")
    func canvasTransforms() throws {
        let fixture = try fixture(textured: true)
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let model = fixture.model
        let size = Size(width: 700, height: 600)
        let center = Point(size.width / 2, size.height / 2)
        for orientation in TileOrientation.allCases {
            model.brushOrientation = orientation
            model.paint(at: center, in: size)
            model.endStroke()
            let container = UIContainerView(rootView: EditorTileMapCanvas(model: model))
            container.frame = Rect(origin: .zero, size: size)
            container.bounds.size = size
            container.layoutIfNeeded()
            let context = UIGraphicsContext()
            container.viewTree.rootNode.draw(with: context)
            var found = false
            for command in context.getDrawCommands() {
                guard case let .drawQuad(transform, texture, _) = command, texture != nil else { continue }
                found = true
                let position = transform * Vector4(0, 0, 0, 1)
                #expect(abs(position.x - center.x) < 0.01)
                #expect(abs(position.y + center.y) < 0.01)
                let corner = transform * Vector4(0.5, 0.5, 0, 1)
                #expect(abs(abs(corner.x - center.x) - model.displayTileSize.width / 2) < 0.01)
                #expect(abs(abs(corner.y + center.y) - model.displayTileSize.height / 2) < 0.01)
            }
            #expect(found)
        }
    }

    @Test("Brush and selected-cell menus apply choices through the actual sidebar")
    func sidebarMenus() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let model = fixture.model
        var menu: ContextMenuPresentation?
        let previous = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { menu = $0 }
        defer { ContextMenuPresentationCenter.present = previous }
        func choose(_ id: String, _ label: String) throws {
            let container = UIContainerView(rootView: EditorTileMapSidebar(model: model))
            container.frame = Rect(x: 0, y: 0, width: 380, height: 1100)
            container.bounds.size = container.frame.size
            container.layoutIfNeeded()
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.TileMapEditor.\(id)"))
            let action = try #require(menu?.items.first { $0.title == label }?.action)
            action()
        }
        try choose("BrushOrientation", TileOrientation.rotate90.editorLabel)
        #expect(model.brushOrientation == .rotate90)
        model.paint(at: Point(350, 300), in: Size(width: 700, height: 600))
        model.endStroke()
        model.selectCell(at: Point(350, 300), in: Size(width: 700, height: 600))
        try choose("CellOrientation", TileOrientation.mirrorXRotate180.editorLabel)
        #expect(model.selectedCellOrientation == .mirrorXRotate180)
    }

    private func fixture(textured: Bool = false) throws -> (model: EditorTileMapEditorModel, url: URL) {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TileOrientation")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Layout.tilemap")
        var map = EditorTileMapResource(atlasColors: [.red], cells: [])
        if textured {
            try Image(width: 24, height: 16, color: .red).pngData().write(to: root.appendingPathComponent("Tile.png"))
            map.atlasTextures = ["Tile.png"]
            let scenes = root.appendingPathComponent("Scenes")
            try FileManager.default.createDirectory(at: scenes, withIntermediateDirectories: true)
            var scene = EditorSceneModel.default(projectName: "Tiles")
            let entity = scene.addEntity(template: .tileMap, parentID: scene.rootEntityID)
            let index = try #require(scene.entities.firstIndex { $0.id == entity.id })
            scene.entities[index].components[EditorBuiltInComponentType.tileMap]?["map"] = .string("@res://Layout.tilemap")
            scene.entities[index].components[EditorBuiltInComponentType.tileMap]?["tileDisplaySize"] = .array([.int(24), .int(16)])
            try scene.encodedYAML().write(to: scenes.appendingPathComponent("Main.ascn"), atomically: true, encoding: .utf8)
        }
        try map.write(to: url)
        let document = EditorAssetDocument(
            id: "Tiles",
            title: "Layout.tilemap",
            relativePath: "Layout.tilemap",
            absolutePath: url.path,
            assetReference: "@res://Layout.tilemap",
            kind: .tileMap,
            fileExtension: "tilemap",
            byteCount: nil,
            modifiedAt: nil,
            errorMessage: nil
        )
        return (EditorTileMapEditorModel(document: document), url)
    }
}
