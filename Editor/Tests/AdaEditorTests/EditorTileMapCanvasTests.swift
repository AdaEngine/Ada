@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorTileMapCanvasTests {
    @Test("Sparse viewport traversal skips empty space, culls distant tiles and preserves compositing order")
    func sparseTraversal() throws {
        let fixture = try fixture(layers: [
            .init(name: "Ground", zIndex: 0, isEnabled: true, cells: [[0, 0, 0], [10000, 10000, 0]]),
            .init(name: "Hidden", zIndex: 1, isEnabled: false, cells: [[0, 0, 1]]),
            .init(name: "Top", zIndex: 2, isEnabled: true, cells: [[0, 0, 1]])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        var indices: [Int] = []
        let candidates = fixture.model.visitVisibleTiles(in: Size(width: 2000, height: 1200)) { _, _, index in indices.append(index) }
        #expect(indices == [0, 1])
        #expect(candidates == 3)
        fixture.model.selectLayer(2)
        fixture.model.erase(at: Point(1000, 600), in: Size(width: 2000, height: 1200))
        indices = []
        fixture.model.visitVisibleTiles(in: Size(width: 2000, height: 1200)) { _, _, index in indices.append(index) }
        #expect(indices == [0]) // The unsaved live stroke is visible immediately.
    }

    @Test("Dense maps bound traversal by viewport area")
    func denseTraversal() throws {
        let cells = (-20...20).flatMap { y in (-20...20).map { x in [x, y, 0] } }
        let fixture = try fixture(layers: [.init(name: "Dense", zIndex: 0, isEnabled: true, cells: cells)])
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        var drawn = 0
        let candidates = fixture.model.visitVisibleTiles(in: Size(width: 240, height: 240)) { _, _, _ in drawn += 1 }
        #expect(candidates < 200)
        #expect(drawn == candidates)
    }

    @Test("Idle canvas reuses its cached geometry and invalidates after paint, pan, zoom, grid and visibility changes")
    func canvasCache() async throws {
        let fixture = try fixture(layers: [.init(name: "Ground", zIndex: 0, isEnabled: true, cells: [])])
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let model = fixture.model
        let container = UIContainerView(rootView: EditorTileMapCanvas(model: model))
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        func marker() throws -> (UInt64, UInt64) {
            let context = UIGraphicsContext()
            container.viewTree.rootNode.draw(with: context)
            for command in context.getDrawCommands() {
                if case let .beginLayer(id, version, cacheable) = command {
                    #expect(cacheable)
                    return (id, version)
                }
            }
            throw CanvasTestError.missingLayer
        }
        var previous = try marker()
        for _ in 0..<120 {
            let current = try marker()
            #expect(current == previous)
        }
        let changes: [() -> Void] = [
            { model.paint(at: Point(500, 350), in: Size(width: 1000, height: 700)) },
            { model.pan(by: Size(width: 24, height: 12)); model.endPan() },
            { model.setZoom(1.5) },
            { model.showGrid.toggle() },
            { model.endStroke(); model.toggleSelectedLayer() }
        ]
        for change in changes {
            change()
            // Observation invalidation is queued on the main actor, as in a real frame.
            for _ in 0..<20 { await Task.yield() }
            container.update(1.0 / 60)
            container.layoutIfNeeded()
            let current = try marker()
            #expect(current.0 == previous.0)
            #expect(current.1 > previous.1)
            previous = current
        }
    }

    private enum CanvasTestError: Error { case missingLayer }

    private func fixture(layers: [EditorTileMapResource.PaletteLayer]) throws -> (model: EditorTileMapEditorModel, url: URL) {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TileMapCanvasTests")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Canvas.tilemap")
        var map = EditorTileMapResource(atlasColors: [.red, .blue], cells: [])
        map.paletteLayers = layers
        try map.write(to: url)
        let document = EditorAssetDocument(
            id: "canvas", title: "Canvas.tilemap", relativePath: "Canvas.tilemap", absolutePath: url.path,
            assetReference: "@res://Canvas.tilemap", kind: .tileMap, fileExtension: "tilemap",
            byteCount: nil, modifiedAt: nil, errorMessage: nil
        )
        return (EditorTileMapEditorModel(document: document), url)
    }
}
