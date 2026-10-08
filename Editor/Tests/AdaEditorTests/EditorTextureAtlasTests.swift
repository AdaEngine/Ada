@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor texture atlas", .serialized)
struct EditorTextureAtlasTests {
    @Test("adding an external PNG copies it beside the atlas and saves the descriptor")
    @MainActor
    func addsExternalImageAndPersistsAtlas() async throws {
        try setupHeadlessRenderEngineIfNeeded()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporaryURL) }

        let model = EditorTextureAtlasEditorModel(document: fixture.document)
        model.addImages(from: [fixture.sourceURL])

        #expect(
            model.descriptor.images == [
                NamedTextureAtlas.Source(path: "game.images/AdaEngine.png")
            ]
        )
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.atlasURL.deletingLastPathComponent()
                    .appendingPathComponent("game.images/AdaEngine.png").path
            )
        )

        let reloaded = EditorTextureAtlasEditorModel(document: fixture.document)
        #expect(reloaded.descriptor == model.descriptor)

        model.addImages(from: [fixture.sourceURL])
        #expect(model.descriptor.images.count == 1)

        try await waitForPreview(in: model)
        if model.atlasImage == nil {
            Issue.record("Atlas preview did not load: \(model.statusMessage)")
        }
        #expect(model.atlasImage != nil)
    }

    @Test("images already in Assets are referenced without being copied")
    @MainActor
    func referencesProjectImage() async throws {
        try setupHeadlessRenderEngineIfNeeded()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporaryURL) }
        let textureDirectory = fixture.temporaryURL.appendingPathComponent("Assets/Textures", isDirectory: true)
        try FileManager.default.createDirectory(at: textureDirectory, withIntermediateDirectories: true)
        let projectImageURL = textureDirectory.appendingPathComponent("player.png")
        try FileManager.default.copyItem(at: fixture.sourceURL, to: projectImageURL)

        let model = EditorTextureAtlasEditorModel(document: fixture.document)
        model.addImages(from: [projectImageURL])

        #expect(
            model.descriptor.images == [
                NamedTextureAtlas.Source(path: "../Textures/player.png")
            ]
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.atlasURL.deletingLastPathComponent().appendingPathComponent("game.images").path
            )
        )
        try await waitForPreview(in: model)
        #expect(model.atlasImage != nil)
    }

    @Test("project tree opens .atlas files with the atlas editor kind")
    @MainActor
    func recognizesAtlasAsset() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporaryURL) }
        let project = EditorProjectReference(name: "AtlasProject", path: fixture.temporaryURL.path)
        let viewModel = EditorViewModel(project: project)
        let item = try #require(
            viewModel.projectSidebar.items.first {
                $0.relativePath == "Assets/Atlases/game.atlas"
            }
        )

        viewModel.openProjectItem(item)

        guard case let .asset(document)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected an atlas asset document")
            return
        }
        #expect(document.kind == .atlas)
        #expect(document.assetReference == "@res://Atlases/game.atlas")
    }

    @Test("atlas editor exposes an interactive add-images control")
    @MainActor
    func addImagesControl() throws {
        try setupHeadlessRenderEngineIfNeeded()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporaryURL) }
        let model = EditorTextureAtlasEditorModel(document: fixture.document)
        var didRequestImages = false
        let container = UIContainerView(
            rootView: EditorTextureAtlasAssetEditor(
                document: fixture.document,
                model: model,
                onAddImages: { didRequestImages = true }
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 900, height: 600)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let preview = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AtlasEditor.Preview"))
        let sources = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AtlasEditor.Sources"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AtlasEditor.AddImages"))

        #expect(preview.absoluteFrame.maxX <= sources.absoluteFrame.minX)
        #expect(didRequestImages)
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let editorRootURL = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = editorRootURL.appendingPathComponent("Sources/AdaEditor/Assets/AdaEngine.png")
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorTextureAtlasTests-\(UUID().uuidString)", isDirectory: true)
        let atlasDirectory = temporaryURL.appendingPathComponent("Assets/Atlases", isDirectory: true)
        try FileManager.default.createDirectory(at: atlasDirectory, withIntermediateDirectories: true)
        let atlasURL = atlasDirectory.appendingPathComponent("game.atlas")
        try Data(#"{"images":[]}"#.utf8).write(to: atlasURL)

        return Fixture(
            temporaryURL: temporaryURL,
            sourceURL: sourceURL,
            atlasURL: atlasURL,
            document: EditorAssetDocument(
                id: "asset:Assets/Atlases/game.atlas",
                title: "game.atlas",
                relativePath: "Assets/Atlases/game.atlas",
                absolutePath: atlasURL.path,
                assetReference: "@res://Atlases/game.atlas",
                kind: .atlas,
                fileExtension: "atlas",
                byteCount: nil,
                modifiedAt: nil,
                errorMessage: nil
            )
        )
    }

    @MainActor
    private func setupHeadlessRenderEngineIfNeeded() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }

        unsafe RenderEngine.configurations.preferredBackend = .headless
        let app = AppWorlds(main: World(name: "EditorTextureAtlasTests"))
        RenderWorldPlugin().setup(in: app)
    }

    @MainActor
    private func waitForPreview(in model: EditorTextureAtlasEditorModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while model.isLoadingPreview, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(10))
        }
    }

    private struct Fixture {
        let temporaryURL: URL
        let sourceURL: URL
        let atlasURL: URL
        let document: EditorAssetDocument
    }
}
