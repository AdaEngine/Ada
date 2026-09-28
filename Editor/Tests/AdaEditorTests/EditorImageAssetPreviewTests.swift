@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Editor image asset preview")
struct EditorImageAssetPreviewTests {
    @Test("project tree recognizes formats registered with Image")
    @MainActor
    func imageFileClassification() {
        for fileExtension in ["png", "jpg", "jpeg", "bmp", "tga", "TGA", "JPEG"] {
            #expect(EditorViewModel.isImageAsset(URL(fileURLWithPath: "/Assets/image.\(fileExtension)")))
        }
        for fileExtension in ["gif", "tiff", "webp", "txt"] {
            #expect(!EditorViewModel.isImageAsset(URL(fileURLWithPath: "/Assets/image.\(fileExtension)")))
        }
        Image.registerDecoder(EditorTestImageDecoder())
        #expect(EditorViewModel.isImageAsset(URL(fileURLWithPath: "/Assets/image.editorimage")))
    }

    @Test("formatting exposes useful image metadata")
    func metadataFormatting() {
        let document = makeImageDocument()

        #expect(EditorAssetPreviewFormatting.fileType(document) == "PNG image")
        #expect(EditorAssetPreviewFormatting.pixelFormat(.rgba8) == "RGBA8")
        #expect(EditorAssetPreviewFormatting.pixelFormat(.bgra8_sRGB) == "BGRA8 sRGB")
        #expect(EditorAssetPreviewFormatting.fileSize(nil) == "Unknown")
        #expect(EditorAssetPreviewFormatting.fileSize(2_048).isEmpty == false)
    }

    @Test("canvas and information panel fit inside the asset viewer")
    @MainActor
    func imagePreviewLayout() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "EditorImageAssetPreviewTests"))
            RenderWorldPlugin().setup(in: app)
        }

        let container = UIContainerView(
            rootView: EditorImageAssetPreview(
                document: makeImageDocument(),
                previewImage: Image(width: 320, height: 180)
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 900, height: 600)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let canvas = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AssetPreview.Canvas"))
        let information = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AssetPreview.Information"))

        #expect(canvas.absoluteFrame.minX == 16)
        #expect(canvas.absoluteFrame.maxX == 884)
        #expect(canvas.absoluteFrame.maxY <= information.absoluteFrame.minY)
        #expect(information.absoluteFrame.maxX == 884)
        #expect(information.absoluteFrame.maxY <= 584)
    }

    private func makeImageDocument() -> EditorAssetDocument {
        EditorAssetDocument(
            id: "asset:Assets/Textures/player.png",
            title: "player.png",
            relativePath: "Assets/Textures/player.png",
            absolutePath: nil,
            assetReference: "@res://Textures/player.png",
            kind: .image,
            fileExtension: "png",
            byteCount: 2_048,
            modifiedAt: nil,
            errorMessage: nil
        )
    }
}

private struct EditorTestImageDecoder: ImageDecoder {
    let supportedExtensions = ["editorimage"]

    func canDecode(_ data: Data) -> Bool {
        data == Data("Editor test image".utf8)
    }

    func decode(_ data: Data) throws -> Image {
        Image(width: 1, height: 1)
    }
}
