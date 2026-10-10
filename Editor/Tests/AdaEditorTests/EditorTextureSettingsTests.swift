@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Editor texture settings", .serialized)
@MainActor
struct EditorTextureSettingsTests {
    @Test
    func applyReloadAndPreviewUseSavedResourceSettings() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try Data(contentsOf: fixture.url)
        let model = EditorTextureSettingsModel(document: fixture.document)
        #expect(model.isEditable)
        #expect(!model.isDirty)
        model.settings.generateMipmaps = true
        model.settings.sampler.minFilter = .linear
        model.settings.sampler.addressModeU = .repeat
        model.settings.colorSpace = .sRGB
        #expect(await model.applySettings())
        #expect(try Data(contentsOf: fixture.url) == original)
        #expect(!model.isDirty)
        #expect(model.levelCount == 4)
        model.previewLevel = 2
        #expect(model.previewImage?.width == 2)
        #expect(model.previewImage?.height == 1)

        let reopened = EditorTextureSettingsModel(document: fixture.document)
        await reopened.loadPreviewIfNeeded()
        #expect(reopened.settings == model.settings)
        let imported = try Image(contentsOf: fixture.url)
        #expect(imported.importedTextureData?.faces.first?.count == 4)
        #expect(imported.samplerDescription.addressModeU == .repeat)
    }

    @Test
    func refusesExternalEditsAndDirtyOpenSidecar() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = EditorTextureSettingsModel(document: fixture.document)
        model.settings.sampler.magFilter = .linear
        let external = try TextureImportSettings().encoded()
        let sidecar = TextureImportSettings.sidecarURL(for: fixture.url)
        try external.write(to: sidecar)
        #expect(!(await model.applySettings()))
        #expect(model.statusMessage.contains("changed on disk"))
        #expect(try Data(contentsOf: sidecar) == external)
        let dirty = EditorTextureSettingsModel(document: fixture.document, canWrite: { _ in false })
        dirty.settings.sampler.minFilter = .linear
        #expect(!(await dirty.applySettings()))
        #expect(dirty.statusMessage.contains("open texture settings document"))
        #expect(try Data(contentsOf: sidecar) == external)
    }

    @Test
    func malformedMetadataAndSymbolicLinksStayReadOnly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let sidecar = TextureImportSettings.sidecarURL(for: fixture.url)
        try Data("broken json".utf8).write(to: sidecar)
        let invalid = EditorTextureSettingsModel(document: fixture.document)
        #expect(!invalid.isEditable)
        #expect(invalid.hasError)
        #expect(invalid.sourceImage != nil)
        try FileManager.default.removeItem(at: sidecar)
        let linked = fixture.directory.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.url)
        var document = fixture.document
        document.absolutePath = linked.path
        #expect(!EditorTextureSettingsModel(document: document).isEditable)
    }

    @Test
    func inspectorMenuEditsSamplerThroughProductionUI() throws {
        setupRendering()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = EditorTextureSettingsModel(document: fixture.document)
        let container = UIContainerView(rootView: EditorTextureSettingsInspector(model: model))
        container.frame = Rect(x: 0, y: 0, width: 300, height: 1100)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let previous = ContextMenuPresentationCenter.present
        var presentation: ContextMenuPresentation?
        ContextMenuPresentationCenter.present = { presentation = $0 }
        defer { ContextMenuPresentationCenter.present = previous }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.TextureSettings.MinFilter"))
        let menu = try #require(presentation)
        let option = try #require(menu.items.first { $0.title == "Linear" })
        option.action?()
        #expect(model.settings.sampler.minFilter == .linear)
        #expect(model.isDirty)
        let pane = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.TextureSettings"))
        #expect(pane.absoluteFrame.maxX <= 300)
    }

    private func setupRendering() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TextureSettingsTests")))
        }
    }

    private func makeFixture() throws -> (directory: URL, url: URL, document: EditorAssetDocument) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("editor-texture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("image.png")
        try Image(width: 8, height: 4, color: .white).writePNG(to: url)
        let document = EditorAssetDocument(
            id: "asset:image.png",
            title: "image.png",
            relativePath: "image.png",
            absolutePath: url.path,
            assetReference: nil,
            kind: .image,
            fileExtension: "png",
            byteCount: nil,
            modifiedAt: nil,
            errorMessage: nil
        )
        return (directory, url, document)
    }
}
