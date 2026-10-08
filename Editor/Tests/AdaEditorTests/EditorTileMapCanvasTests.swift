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

    @Test("Removing a palette color clears its cells on every layer and reindexes surviving colors")
    func removeColor() throws {
        let fixture = try fixture(layers: [
            .init(name: "Ground", zIndex: 0, isEnabled: true, cells: [[0, 0, 0], [1, 0, 1]]),
            .init(name: "Top", zIndex: 1, isEnabled: false, cells: [[2, 0, 0], [3, 0, 1]])
        ])
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let model = fixture.model
        model.removeSelectedColor()
        let saved = try EditorTileMapResource.read(from: fixture.url)
        #expect(saved.atlasColors == [.blue])
        #expect(saved.effectiveLayers.map(\.cells) == [[[1, 0, 0]], [[3, 0, 0]]])
        #expect(model.selectedColor == 0)
        model.removeSelectedColor()
        #expect(model.paletteCount == 0)
        #expect(model.layers.allSatisfy { $0.cells.isEmpty })
        #expect(!model.canRemoveSelectedColor)
        model.removeSelectedColor()
        #expect(try EditorTileMapResource.read(from: fixture.url).atlasColors.isEmpty)
    }

    @Test("Ruler glyphs retain their point size while the map zooms and pans")
    func rulerGlyphSize() throws {
        let fixture = try fixture(layers: [.init(name: "Ground", zIndex: 0, isEnabled: true, cells: [])])
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let model = fixture.model
        for zoom: Float in [0.25, 1, 4] {
            model.setZoom(zoom)
            model.pan(by: Size(width: 120, height: -80))
            model.endPan()
            let container = UIContainerView(rootView: EditorTileMapCanvas(model: model))
            container.frame = Rect(x: 0, y: 0, width: 1000, height: 700)
            container.bounds.size = container.frame.size
            container.layoutIfNeeded()
            let context = UIGraphicsContext()
            container.viewTree.rootNode.draw(with: context)
            var glyphCount = 0
            for command in context.getDrawCommands() {
                switch command {
                case let .drawGlyph(glyph, transform, _):
                    glyphCount += 1
                    #expect(glyph.attributes.font.pointSize == 9)
                    #expect(glyph.size.height < 16)
                    #expect(transform.scale.x == 1)
                    #expect(transform.scale.y == 1)
                    let topLeft = transform * Vector4(glyph.position.x, glyph.position.w, 0, 1)
                    let bottomRight = transform * Vector4(glyph.position.z, glyph.position.y, 0, 1)
                    #expect(topLeft.x >= 0)
                    #expect(bottomRight.x <= container.frame.width)
                    #expect(-topLeft.y >= 0)
                    #expect(-bottomRight.y <= container.frame.height)
                case let .drawText(layout, transform, _):
                    // Cover the layout command too: rectangle scaling caused the regression.
                    glyphCount += layout.textLines.reduce(0) { count, line in
                        count + line.reduce(0) { $0 + $1.count }
                    }
                    #expect(transform.scale.x == 1)
                    #expect(transform.scale.y == 1)
                default:
                    break
                }
            }
            #expect(glyphCount > 2)
        }
    }

    @Test("Every tilemap toolbar button draws its icon from the bundled font")
    func toolbarGlyphs() throws {
        let fixture = try fixture(layers: [.init(name: "Ground", zIndex: 0, isEnabled: true, cells: [])])
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let container = UIContainerView(rootView: EditorTileMapAssetEditor(document: fixture.document, model: fixture.model))
        container.frame = Rect(x: 0, y: 0, width: 1200, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        for id in ["Paint", "Erase", "Pan", "ZoomOut", "ZoomIn", "Fit", "Grid", "Reload"] {
            let node = try #require(container.viewTree.rootNode.findNodyByAccessibilityIdentifier("AdaEditor.TileMapEditor.\(id)"))
            let context = UIGraphicsContext()
            node.draw(with: context)
            var glyphCount = 0
            for command in context.getDrawCommands() {
                switch command {
                case let .drawGlyph(glyph, _, _):
                    #expect(glyph.size.width > 0 && glyph.size.height > 0, "Missing icon for \(id)")
                    glyphCount += 1
                case let .drawText(layout, _, _):
                    glyphCount += layout.textLines.reduce(0) { count, line in count + line.reduce(0) { $0 + $1.count } }
                default:
                    break
                }
            }
            #expect(glyphCount == 1, "Missing icon for \(id)")
        }
    }

    private enum CanvasTestError: Error { case missingLayer }

    private func fixture(layers: [EditorTileMapResource.PaletteLayer]) throws -> (model: EditorTileMapEditorModel, url: URL, document: EditorAssetDocument) {
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
            id: "canvas",
            title: "Canvas.tilemap",
            relativePath: "Canvas.tilemap",
            absolutePath: url.path,
            assetReference: "@res://Canvas.tilemap",
            kind: .tileMap,
            fileExtension: "tilemap",
            byteCount: nil,
            modifiedAt: nil,
            errorMessage: nil
        )
        return (EditorTileMapEditorModel(document: document), url, document)
    }
}
