@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor tile source", .serialized)
struct EditorTileSourceTests {
    @Test @MainActor
    func persistedSourceLoadsInRuntime() async throws {
        try setupRenderer()
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = EditorTileSourceEditorModel(document: fixture.document)
        model.addImages([fixture.png])
        #expect(model.image != nil, "\(model.status)")
        #expect(model.sources.count == 1)
        #expect(model.layout?.path.hasPrefix("game.images/") == true)
        model.width = "16"
        model.height = "16"
        model.spacingX = "1"
        model.spacingY = "2"
        model.marginX = "3"
        model.marginY = "4"
        model.applySettings()
        model.selectTile([0, 0])
        model.toggleTile()
        model.frames = "2"
        model.duration = "0.5"
        model.applyAnimation()
        #expect(model.tiles.count == 1)
        let reloaded = EditorTileSourceEditorModel(document: fixture.document)
        #expect(reloaded.layout == model.layout)
        reloaded.selectTile([0, 0])
        #expect(reloaded.frames == "2")
        #expect(reloaded.duration == "0.5")

        TextureAtlasTileSource.registerTileSource()
        let handle = try await AssetsManager.load(TileSet.self, at: fixture.file.path)
        let tileSet = try #require(handle.asset)
        let source = try #require(tileSet.sources[0] as? TextureAtlasTileSource)
        #expect(source.hasTile(at: [0, 0]))
        let texture = source.getTexture(at: [0, 0])
        #expect(texture is AnimatedTexture)
        // Verify margin and spacing use the same pixel rectangle as the editor.
        let atlas = TextureAtlas(from: try #require(model.image), size: [16, 16], margin: [1, 2], offset: [3, 4])
        let slice = atlas.textureSlice(at: [1, 1])
        #expect(slice.position == [20, 22])
        #expect(slice.width == 16)
        #expect(slice.textureCoordinates[1].x == Float(36) / Float(atlas.width))
        #expect(slice.textureCoordinates[1].y == Float(38) / Float(atlas.height))
    }

    @Test @MainActor
    func conflictsAndInvalidSettingsDoNotOverwrite() throws {
        try setupRenderer()
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = EditorTileSourceEditorModel(document: fixture.document)
        model.addImages([fixture.png])
        model.selectTile([0, 0])
        model.toggleTile()
        let original = try Data(contentsOf: fixture.file)
        model.width = "0"
        model.applySettings()
        #expect(try Data(contentsOf: fixture.file) == original)
        model.frames = "99999"
        model.applyAnimation()
        #expect(try Data(contentsOf: fixture.file) == original)
        let external = Data("tileSize: {x: 32, y: 32}\nsources: []\ncustom: keep\n".utf8)
        try external.write(to: fixture.file)
        model.removeSource()
        #expect(try Data(contentsOf: fixture.file) == external)
        #expect(model.sources.isEmpty)
        #expect(model.status.contains("changed on disk"))
        model.displayWidth = "24"
        model.applySettings()
        #expect(try String(contentsOf: fixture.file, encoding: .utf8).contains("custom: keep"))
    }

    @Test @MainActor
    func tileCreationAndSourceIDsSurviveRemoval() throws {
        try setupRenderer()
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = EditorTileSourceEditorModel(document: fixture.document)
        model.addImages([fixture.png, fixture.png])
        #expect(model.sources.count == 2)
        model.selectSource(0)
        model.removeSource()
        #expect(model.sourceData["id"] as? Int == 1)
        model.createAllTiles()
        let count = model.gridSize.width * model.gridSize.height
        #expect(model.tiles.count == count)
        model.createAllTiles()
        #expect(model.tiles.count == count)
        model.selectTile([0, 0])
        model.toggleTile()
        #expect(!model.hasTile([0, 0]))
        model.selectTile([-1, 0])
        #expect(model.selectedTile == [0, 0])
        model.width = "1048576"
        let before = try Data(contentsOf: fixture.file)
        model.applySettings()
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test @MainActor
    func routesTilesetAndOperatesRealUI() throws {
        try setupRenderer()
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = EditorViewModel(project: EditorProjectReference(name: "Tiles", path: fixture.root.path))
        let item = try #require(project.projectSidebar.items.first { $0.relativePath == "Assets/game.tileset" })
        project.openProjectItem(item)
        guard case let .asset(document)? = project.workbench.activeDocument else {
            Issue.record("Expected a visual tile source asset document")
            return
        }
        #expect(document.kind == .tileSource)
        #expect(project.toolStrip.activeRightTool == "inspector")
        #expect(project.showRightPanel)
        #expect(document.absolutePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == fixture.file.standardizedFileURL.path)
        let model = project.workbench.tileSourceModel(for: document)
        model.addImages([fixture.png, fixture.png])
        #expect(model.sources.count == 2)
        model.selectTile([0, 0])
        try #require(model.image != nil, "\(model.status)")
        let container = UIContainerView(rootView: EditorTileSourceAssetEditor(document: document, model: model))
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 1100)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileSourceEditor.Preview"))
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileSourceEditor.Canvas"))
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileSourceEditor.Source.1"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.TileSourceEditor.Source.0"))
        #expect(model.selectedSource == 0)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.TileSourceEditor.ZoomIn"))
        #expect(model.zoom > 1)
        let inspector = UIContainerView(rootView: EditorContextualInspector(
            document: .asset(document),
            workbench: project.workbench,
            sceneInspectorViewModel: project.inspectorSidebar,
            resourceRootURL: nil
        ))
        inspector.frame = Rect(x: 0, y: 0, width: 300, height: 1100)
        inspector.bounds.size = inspector.frame.size
        inspector.layoutIfNeeded()
        _ = try inspector.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileSourceEditor.Inspector"))
        _ = try inspector.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.TileSourceEditor.CreateAll"))
        #expect(!model.tiles.isEmpty)
        let reloaded = EditorTileSourceEditorModel(document: document)
        reloaded.selectSource(model.selectedSource)
        #expect(reloaded.tiles.count == model.tiles.count)
    }

    @Test @MainActor
    func viewportNavigationPreservesAnchorAndSelection() throws {
        try setupRenderer()
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = EditorTileSourceEditorModel(document: fixture.document)
        model.addImages([fixture.png])
        model.selectTile([0, 0])
        let original = try Data(contentsOf: fixture.file)
        let viewport = Size(width: 800, height: 600)
        let anchor = Point(600, 400)
        model.setZoom(2, around: anchor, in: viewport)
        #expect(model.zoom == 2)
        #expect(model.panOffset == Point(-200, -100))
        model.setZoom(1, around: anchor, in: viewport)
        #expect(model.panOffset == .zero)
        model.setZoom(.nan, around: anchor, in: viewport)
        #expect(model.zoom == 1)
        model.setZoom(100, around: anchor, in: viewport)
        #expect(model.zoom == 16)
        model.setZoom(0, around: anchor, in: viewport)
        #expect(model.zoom == 0.25)
        model.handleSecondaryDrag(MouseEvent(window: .empty, button: .right, mousePosition: Point(20, 30), phase: .began, modifierKeys: [], time: 0))
        let start = model.panOffset
        model.handleSecondaryDrag(MouseEvent(window: .empty, button: .right, mousePosition: Point(50, 70), phase: .changed, modifierKeys: [], time: 0))
        #expect(model.panOffset == Point(start.x + 30, start.y + 40))
        model.handleSecondaryDrag(MouseEvent(window: .empty, button: .right, mousePosition: Point(50, 70), phase: .cancelled, modifierKeys: [], time: 0))
        let end = model.panOffset
        model.handleSecondaryDrag(MouseEvent(window: .empty, button: .right, mousePosition: Point(90, 90), phase: .changed, modifierKeys: [], time: 0))
        #expect(model.panOffset == end)
        #expect(model.selectedTile == [0, 0])
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test @MainActor
    func canvasReceivesNavigationEvents() throws {
        try setupRenderer()
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = EditorTileSourceEditorModel(document: fixture.document)
        model.addImages([fixture.png])
        let original = try Data(contentsOf: fixture.file)
        let container = UIContainerView(rootView: EditorTileSourceAssetEditor(document: fixture.document, model: model))
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 800)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let canvas = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TileSourceEditor.Canvas"))
        let frame = canvas.absoluteFrame
        let point = Point(frame.midX, frame.midY)
        container.onMouseEvent(MouseEvent(window: .empty, button: .scrollWheel, scrollDelta: Point(0, 1), mousePosition: point, phase: .changed, modifierKeys: [], time: 0))
        #expect(abs(model.zoom - 1.12) < 0.001)
        container.onReceiveEvent(PinchEvent(window: .empty, location: point, scale: 1, phase: .began, time: 0))
        container.onReceiveEvent(PinchEvent(window: .empty, location: point, scale: 2, phase: .changed, time: 0))
        #expect(abs(model.zoom - 2.24) < 0.001)
        container.onReceiveEvent(PinchEvent(window: .empty, location: point, scale: 2, phase: .ended, time: 0))
        let start = model.panOffset
        container.onMouseEvent(MouseEvent(window: .empty, button: .right, mousePosition: point, phase: .began, modifierKeys: [], time: 0))
        let end = Point(point.x + 40, point.y + 20)
        container.onMouseEvent(MouseEvent(window: .empty, button: .right, mousePosition: end, phase: .changed, modifierKeys: [], time: 0))
        container.onMouseEvent(MouseEvent(window: .empty, button: .right, mousePosition: end, phase: .ended, modifierKeys: [], time: 0))
        #expect(model.panOffset == Point(start.x + 40, start.y + 20))
        #expect(model.selectedTile == nil)
        #expect(try Data(contentsOf: fixture.file) == original)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.TileSourceEditor.Fit"))
        #expect(model.zoom == 1)
        #expect(model.panOffset == .zero)
    }

    @Test func gridExcludesPartialCells() {
        let descriptor = TileSourceImageDescriptor(path: "sheet.png", tileSize: [16, 16], margin: [2, 2], spacing: [1, 1])
        #expect(descriptor.gridSize(imageSize: [54, 37]) == [3, 2])
        #expect(descriptor.gridSize(imageSize: [19, 19]) == .zero)
    }

    @MainActor private func setupRenderer() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }
        unsafe RenderEngine.configurations.preferredBackend = .headless
        RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TileSourceTests")))
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TileSourceTests-\(UUID())")
        let assets = root.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let file = assets.appendingPathComponent("game.tileset")
        try Data("tileSize: {x: 16, y: 16}\nsources: []\n".utf8).write(to: file)
        let editor = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Fixture(
            root: root,
            file: file,
            png: editor.appendingPathComponent("Sources/AdaEditor/Assets/AdaEngine.png"),
            document: EditorAssetDocument(
                id: "tiles",
                title: "game.tileset",
                relativePath: "Assets/game.tileset",
                absolutePath: file.path,
                assetReference: "@res://game.tileset",
                kind: .tileSource,
                fileExtension: "tileset",
                byteCount: nil,
                modifiedAt: nil,
                errorMessage: nil
            )
        )
    }

    private struct Fixture {
        let root: URL
        let file: URL
        let png: URL
        let document: EditorAssetDocument
    }
}
