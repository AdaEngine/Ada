@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorTileMapLifetimeTests {
    @Test("A document retains its tile map model and edits until it is closed or discarded")
    func documentLifetime() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workbench = EditorWorkbenchViewModel()
        workbench.open(.asset(fixture.document))
        let model = workbench.tileMapModel(for: fixture.document)
        model.selectedColor = 1
        model.setZoom(1.5)
        model.pan(by: Size(width: 40, height: 20))
        model.endPan()
        model.addLayer()
        let viewport = Size(width: 600, height: 400)
        model.paint(at: model.canvasOrigin(in: viewport), in: viewport)
        model.endStroke()
        #expect(workbench.tileMapResourceRevision == 2)
        let revision = model.revision
        let texture = try #require(model.texture(at: 0))
        for _ in 0..<20 {
            let retained = workbench.tileMapModel(for: fixture.document)
            #expect(retained === model)
            #expect(retained.revision == revision)
            #expect(retained.texture(at: 0) === texture)
            #expect(retained.selectedLayer == 1)
            #expect(retained.selectedColor == 1)
            #expect(retained.zoom == 1.5)
            #expect(retained.panOffset == Point(x: 40, y: 20))
        }
        workbench.closeDocument(id: fixture.document.id)
        #expect(workbench.tileMapModels[fixture.document.id] == nil)
        workbench.open(.asset(fixture.document))
        let reopened = workbench.tileMapModel(for: fixture.document)
        #expect(reopened !== model)
        #expect(reopened.tileIndex(atX: 0, y: 0, layer: 1) == 1)
        workbench.discardDocuments(atOrBelow: fixture.document.relativePath)
        #expect(workbench.tileMapModels.isEmpty)
    }

    @Test("Constructing a tile map view defers document loading until it is mounted")
    func deferredModelLoading() throws {
        let fixture = try fixture(writeMap: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var saves = 0
        let view = EditorTileMapAssetEditor(document: fixture.document, onSave: { saves += 1 })
        try fixture.map.write(to: fixture.url)
        let container = UIContainerView(rootView: view)
        container.frame = Rect(x: 0, y: 0, width: 1_000, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let canvas = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileMapEditor.Canvas"))
        let point = Point(x: canvas.absoluteFrame.midX, y: canvas.absoluteFrame.midY)
        for phase: MouseEvent.Phase in [.began, .ended] {
            container.onMouseEvent(MouseEvent(
                window: .empty, button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0
            ))
        }
        #expect(saves == 1)
        #expect(try EditorTileMapResource.read(from: fixture.url).cells == [[0, 0, 0]])
    }

    @Test("Palette rebuilds draw the model's existing textures and reload replaces them")
    func paletteTextureReuse() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = EditorTileMapEditorModel(document: fixture.document)
        let container = UIContainerView(rootView: EditorTileMapSidebar(model: model))
        container.frame = Rect(x: 0, y: 0, width: 280, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let textures = try (0..<2).map { try #require(model.texture(at: $0)) }
        func drawnTextures() -> [Texture2D] {
            let context = UIGraphicsContext()
            container.viewTree.rootNode.draw(with: context)
            return context.getDrawCommands().compactMap { command in
                if case let .drawQuad(_, texture, _) = command {
                    return texture
                }
                return nil
            }
        }
        for index in 0..<12 {
            model.selectedColor = index % 2
            for _ in 0..<20 { await Task.yield() }
            container.update(1.0 / 60)
            container.layoutIfNeeded()
            let drawn = drawnTextures()
            for texture in textures {
                #expect(drawn.contains { $0 === texture })
            }
        }
        model.reload()
        for _ in 0..<20 { await Task.yield() }
        container.update(1.0 / 60)
        container.layoutIfNeeded()
        let replacement = try #require(model.texture(at: 0))
        #expect(replacement !== textures[0])
        #expect(drawnTextures().contains { $0 === replacement })
        #expect(!drawnTextures().contains { $0 === textures[0] })
    }

    private func fixture(writeMap: Bool = true) throws -> (
        root: URL, url: URL, document: EditorAssetDocument, map: EditorTileMapResource
    ) {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TileMapLifetimeTests")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let imageURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/MedievalArena/Assets/Tiles/tile_0000.png")
        try FileManager.default.copyItem(at: imageURL, to: root.appendingPathComponent("tile.png"))
        let url = root.appendingPathComponent("Map.tilemap")
        let map = EditorTileMapResource(atlasColors: [.red, .blue], atlasTextures: ["tile.png", "tile.png"], cells: [])
        if writeMap { try map.write(to: url) }
        let document = EditorAssetDocument(
            id: "asset:Map.tilemap",
            title: "Map.tilemap",
            relativePath: "Map.tilemap",
            absolutePath: url.path,
            assetReference: "@res://Map.tilemap",
            kind: .tileMap,
            fileExtension: "tilemap",
            byteCount: nil,
            modifiedAt: nil,
            errorMessage: nil
        )
        return (root, url, document, map)
    }
}
