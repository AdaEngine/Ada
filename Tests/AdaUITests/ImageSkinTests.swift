import AdaInput
import AdaRender
@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Foundation
import Math
import Testing

@MainActor
struct ImageSkinTests {
    init() async throws { try Application.prepareForTest() }

    @Test func preservesCornersAndTilesDestination() {
        let grid = ImageSliceGrid(width: 100, height: 60, insets: .init(top: 6, leading: 8, bottom: 10, trailing: 12))
        let frame = Rect(x: 30, y: 40, width: 300, height: 200)
        #expect(grid.destinationRect(column: 0, row: 0, frame: frame) == Rect(x: 30, y: 40, width: 8, height: 6))
        #expect(grid.destinationRect(column: 2, row: 2, frame: frame) == Rect(x: 318, y: 230, width: 12, height: 10))
        var area: Float = 0
        for row in 0..<3 {
            for column in 0..<3 {
                let rect = grid.destinationRect(column: column, row: row, frame: frame)
                area += rect.size.width * rect.size.height
            }
        }
        #expect(area == 60000)
    }

    @Test func undersizedDestinationShrinksOpposingCaps() {
        let grid = ImageSliceGrid(width: 40, height: 40, insets: .init(10))
        let frame = Rect(x: 0, y: 0, width: 12, height: 8)
        #expect(grid.destinationRect(column: 0, row: 0, frame: frame).size == Size(width: 6, height: 4))
        #expect(grid.destinationRect(column: 1, row: 1, frame: frame).size == .zero)
        let clamped = ImageSliceGrid(width: 1, height: 1, insets: .init(Int.max))
        #expect(clamped.sourceRect(column: 1, row: 1) == RectInt(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func slicesShareTextureAndUseCorrectUVs() throws {
        let atlas = TextureAtlas(from: Image(width: 100, height: 50), size: SizeInt(width: 100, height: 50))
        let slice = try #require(atlas.textureSlice(in: RectInt(x: 10, y: 5, width: 20, height: 10)))
        #expect(slice.atlas === atlas)
        #expect(slice.textureCoordinates == [Vector2(0.1, 0.3), Vector2(0.3, 0.3), Vector2(0.3, 0.1), Vector2(0.1, 0.1)])
        #expect(atlas.textureSlice(in: RectInt(x: 90, y: 0, width: 20, height: 10)) == nil)
    }

    @Test func imageNodeDrawsNineQuadsWithSharedAtlas() throws {
        let image = Image(width: 40, height: 40)
        let node = ImageViewNode(image: image, isResizable: true, renderMode: .original, tintColor: nil, capInsets: .init(8), content: image)
        node.place(in: .zero, anchor: .topLeading, proposal: ProposedViewSize(width: 200, height: 100))
        let context = UIGraphicsContext()
        node.draw(with: context)
        let textures = context.getDrawCommands().compactMap { command -> TextureAtlas.Slice? in
            if case .drawQuad(_, let texture, _) = command { return texture as? TextureAtlas.Slice }
            return nil
        }
        #expect(textures.count == 9)
        let first = try #require(textures.first)
        #expect(textures.allSatisfy { $0.atlas === first.atlas })
    }

    @Test func imageNodeReplacesTextureDuringViewUpdates() {
        let firstImage = Image(width: 16, height: 16, color: .red)
        let secondImage = Image(width: 16, height: 16, color: .blue)
        let node = ImageViewNode(image: firstImage, isResizable: false, renderMode: .original, tintColor: nil, content: firstImage)
        let replacement = ImageViewNode(image: secondImage, isResizable: true, renderMode: .template, tintColor: .green, content: secondImage)
        let firstTexture = node.texture

        node.update(from: replacement)

        #expect(node.texture === replacement.texture)
        #expect(node.texture !== firstTexture)
        #expect(node.isResizable)
        #expect(node.renderMode == .template)
        #expect(node.tintColor == .green)
    }

    @Test func statePriorityAndFallback() {
        let style = TextureButtonStyle(normal: Image(width: 1, height: 1), highlighted: Image(width: 2, height: 1), pressed: Image(width: 3, height: 1), disabled: Image(width: 4, height: 1))
        #expect(style.image(for: .normal).width == 1)
        #expect(style.image(for: .focused).width == 2)
        #expect(style.image(for: [.selected, .highlighted]).width == 3)
        #expect(style.image(for: [.disabled, .selected]).width == 4)
        #expect(TextureButtonStyle(normal: style.normal).image(for: .disabled).width == 1)
    }

    @Test func skinnedButtonDispatchesClicksAndBlocksDisabledInput() {
        var clicks = 0
        let skin = TextureButtonStyle(normal: Image(width: 24, height: 24), capInsets: .init(4))
        for disabled in [false, true] {
            let tester = ViewTester {
                Button(action: { clicks += 1 }) { Color.white.frame(width: 100, height: 44) }
                    .buttonStyle(skin).disabled(disabled)
            }.setSize(Size(width: 200, height: 100)).performLayout()
            tester.sendMouseEvent(at: Point(100, 50), button: .left, phase: .began)
            tester.sendMouseEvent(at: Point(100, 50), button: .left, phase: .ended)
            #expect(clicks == 1)
        }
    }

    @Test func designerMenuLoadsRealResources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Demos/Resources/KenneyUI")
        let resources = UISceneResources(rootURL: root)
        let url = root.appendingPathComponent("Menu.ui")
        let document = try resources.load(url)
        let context = UIBindingContext()
        for index in 0..<4 { context.on("action\(index)") { _ in } }
        let scene = try UISceneInstance(document: document, context: context, resources: resources, sourceURL: url)
        let tester = ViewTester { UISceneView(session: scene) }.setSize(Size(width: 400, height: 500)).performLayout()
        #expect(tester.containerView.frame.size.width == 400)
        #expect(resources.dependencies.filter { $0.pathExtension == "png" }.count == 5)
        let decoded = try UISceneDocument.decode(document.encodedYAML())
        #expect(decoded.root == document.root)
    }
}
