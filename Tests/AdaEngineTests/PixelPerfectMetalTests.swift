#if os(macOS)
@_spi(Internal) @testable import AdaApp
import AdaAssets
@testable import AdaCorePipelines
import AdaECS
import AdaInput
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaSprite
import AdaText
import AdaTransform
import AdaUI
import AdaUtils
import Foundation
import Math
import Metal
import Testing

private let pixelPerfectSAGASmokeEnabled = ProcessInfo.processInfo.environment["ADAENGINE_PIXEL_PERFECT_SAGA_SMOKE"] == "1"
private let pixelPerfectGPUSmokeEnabled =
    pixelPerfectSAGASmokeEnabled || ProcessInfo.processInfo.environment["ADAENGINE_PIXEL_PERFECT_METAL_SMOKE"] == "1"

/// Renders a pixel-perfect camera through the whole engine (camera extraction, render target preparation, the
/// 2D render graph and the upscale node) on Metal and reads the output back.
/// Run alone in a fresh process, like the other Metal suites:
/// `ADAENGINE_PIXEL_PERFECT_METAL_SMOKE=1 swift test --filter PixelPerfectMetalTests`
@Suite("Pixel perfect GPU rendering", .serialized)
@MainActor
struct PixelPerfectMetalTests {
    private let scene = Color(red: 0.1, green: 0.2, blue: 0.6, alpha: 1)
    private let letterbox = Color(red: 0.9, green: 0.1, blue: 0.9, alpha: 1)

    @Test(.enabled(if: pixelPerfectGPUSmokeEnabled))
    func integerScaleCentresACrispPicture() async throws {
        // 8x6 art pixels into a 40x28 output: 4x scale, a 32x24 picture at (4, 2).
        let frame = try await render(output: SizeInt(width: 40, height: 28), resolution: SizeInt(width: 8, height: 6))
        let image = frame.image

        // The border is the letterbox colour on all four sides.
        for point in [(0, 0), (39, 27), (3, 14), (36, 14), (20, 0), (20, 27), (20, 1)] {
            expectColor(image.getPixel(x: point.0, y: point.1), letterbox, "border at \(point)")
        }
        // The picture starts exactly at (4, 2) and ends at (35, 25), in the scene's background colour.
        expectColor(image.getPixel(x: 4, y: 2), .red, "top-left art pixel")
        expectColor(image.getPixel(x: 35, y: 25), .green, "bottom-right art pixel")
        expectColor(image.getPixel(x: 20, y: 14), scene, "scene background")

        // One art pixel is a 4x4 block with hard edges: no blending with its neighbours.
        expectColor(image.getPixel(x: 4, y: 2), .red, "block start")
        expectColor(image.getPixel(x: 7, y: 5), .red, "block end")
        expectColor(image.getPixel(x: 8, y: 2), scene, "pixel after block, same row")
        expectColor(image.getPixel(x: 4, y: 6), scene, "pixel after block, same column")
        expectColor(image.getPixel(x: 32, y: 22), .green, "second block start")
        expectColor(image.getPixel(x: 31, y: 22), scene, "pixel before second block")
        expectColor(image.getPixel(x: 32, y: 21), scene, "row above second block")

        // Every pixel of the picture is one of the three picture colours: scaling invented no intermediate colour.
        var strays = 0
        for y in 2..<26 {
            for x in 4..<36 {
                let pixel = image.getPixel(x: x, y: y)
                if !(isClose(pixel, scene) || isClose(pixel, .red) || isClose(pixel, .green)) { strays += 1 }
            }
        }
        #expect(strays == 0, "\(strays) picture pixels were blended")
    }

    @Test(.enabled(if: pixelPerfectGPUSmokeEnabled))
    func scaleFollowsTheOutputSize() async throws {
        // The same 8x6 picture in a 100x50 output: 8x scale, a 64x48 picture at (18, 1).
        let frame = try await render(output: SizeInt(width: 100, height: 50), resolution: SizeInt(width: 8, height: 6))
        let image = frame.image
        expectColor(image.getPixel(x: 17, y: 20), letterbox, "left border")
        expectColor(image.getPixel(x: 82, y: 20), letterbox, "right border")
        expectColor(image.getPixel(x: 18, y: 1), .red, "top-left art pixel")
        expectColor(image.getPixel(x: 25, y: 8), .red, "its last texel")
        expectColor(image.getPixel(x: 26, y: 1), scene, "next art pixel")
        expectColor(image.getPixel(x: 81, y: 48), .green, "bottom-right art pixel")
    }

    @Test(.enabled(if: pixelPerfectGPUSmokeEnabled))
    func fitModeFillsTheLimitingAxis() async throws {
        let frame = try await render(output: SizeInt(width: 40, height: 28), resolution: SizeInt(width: 8, height: 6), mode: .fit)
        let image = frame.image
        // Fit scale is min(40/8, 28/6) = 4.666…: 37.33 x 28 picture, so no border above or below and a border left and right.
        expectColor(image.getPixel(x: 0, y: 14), letterbox, "left border")
        expectColor(image.getPixel(x: 20, y: 0), scene, "no border above (or the red/green art pixel)", allowing: [.red, .green])
        expectColor(image.getPixel(x: 20, y: 27), scene, "no border below", allowing: [.red, .green])
    }

    @Test(.enabled(if: pixelPerfectGPUSmokeEnabled))
    func aCameraWithoutThePresetStillFillsTheOutput() async throws {
        let frame = try await render(output: SizeInt(width: 40, height: 28), resolution: nil)
        let image = frame.image
        // Without the preset there is no border: the corners are scene background (or the marker pixels).
        for point in [(0, 0), (39, 27), (0, 27), (39, 0)] {
            let pixel = image.getPixel(x: point.0, y: point.1)
            #expect(!isClose(pixel, letterbox), "corner \(point) is letterboxed without the preset")
        }
    }

    @Test(.enabled(if: pixelPerfectGPUSmokeEnabled))
    func uiIsDrawnAtOutputResolutionOnTopOfTheScaledScene() async throws {
        // 8x6 art pixels into 40x28: 4x scale, picture at (4, 2). Two UI blocks are placed in output pixels:
        // one inside the picture at an offset that is not a multiple of the scale, one in the border.
        let blocks = [Rect(x: 6, y: 20, width: 10, height: 3), Rect(x: 0, y: 10, width: 3, height: 4)]
        let frame = try await render(output: SizeInt(width: 40, height: 28), resolution: SizeInt(width: 8, height: 6), uiBlocks: blocks)
        let image = frame.image
        let ui = Color(red: 1, green: 1, blue: 0, alpha: 1)

        // The block is exactly 10x3 output pixels: its edges are not on art-pixel boundaries (4-pixel steps from x = 4).
        expectColor(image.getPixel(x: 6, y: 20), ui, "block first pixel")
        expectColor(image.getPixel(x: 15, y: 22), ui, "block last pixel")
        expectColor(image.getPixel(x: 5, y: 20), scene, "pixel left of the block")
        expectColor(image.getPixel(x: 16, y: 20), scene, "pixel right of the block")
        expectColor(image.getPixel(x: 6, y: 19), scene, "pixel above the block")
        expectColor(image.getPixel(x: 6, y: 23), scene, "pixel below the block")
        // A block in the border: only possible because the UI is not part of the low-resolution picture.
        expectColor(image.getPixel(x: 0, y: 10), ui, "border block first pixel")
        expectColor(image.getPixel(x: 2, y: 13), ui, "border block last pixel")
        expectColor(image.getPixel(x: 3, y: 10), letterbox, "border right of the block")
        // The scene underneath is still there and still crisp.
        expectColor(image.getPixel(x: 4, y: 2), .red, "top-left art pixel")
        expectColor(image.getPixel(x: 35, y: 25), .green, "bottom-right art pixel")
        expectColor(image.getPixel(x: 39, y: 27), letterbox, "far corner")
    }

    // MARK: - Fixture

    /// Draws a fullscreen triangle sampling one colour, clipped by a scissor rectangle in output pixels.
    struct BlockDrawPass: DrawPass {
        typealias Item = UITransparentRenderItem
        let pipeline: RenderPipeline
        let sampler: Sampler
        let texture: Texture2D
        let block: Rect

        func render(with renderEncoder: RenderCommandEncoder, world: World, view: Entity, item: UITransparentRenderItem) throws {
            renderEncoder.setScissorRect(block)
            renderEncoder.setResourceSet(
                RenderResourceSet(bindings: [
                    RenderResourceSet.Binding(binding: 0, shaderStages: .fragment, resource: .texture(texture)),
                    RenderResourceSet.Binding(binding: 1, shaderStages: .fragment, resource: .sampler(sampler)),
                ]),
                index: 0
            )
            renderEncoder.setRenderPipelineState(pipeline)
            renderEncoder.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
        }
    }

    /// Puts the test blocks into the UI render items right before the render graph runs, after the UI systems built theirs.
    struct BlockSetup: Resource {
        var blocks: [Rect]
    }

    /// Registers the injection in the render world once plugins are set up in order, after the UI plugin.
    struct InjectBlocksPlugin: Plugin {
        let blocks: [Rect]

        func setup(in app: AppWorlds) {
            app.getSubworldBuilder(by: .renderWorld)?
                .insertResource(BlockSetup(blocks: blocks))
                .addSystem(InjectBlocksSystem.self, on: .render)
        }
    }

    @PlainSystem(dependencies: [.before(RenderSystem.self)])
    struct InjectBlocksSystem {
        @ResMut<RenderItems<UITransparentRenderItem>> private var items
        @Res<BlockSetup> private var setup
        @Res<PixelPerfectPipelines> private var pipelines
        @Res<UIRenderPipelines> private var uiPipelines
        @Res<RenderDeviceHandler> private var device

        init(world _: World) {}

        func update(context _: UpdateContext) {
            let texture = Texture2D(image: Image(width: 1, height: 1, color: Color(red: 1, green: 1, blue: 0, alpha: 1)))
            items.items.removeAll()
            for block in setup.blocks {
                items.items.append(UITransparentRenderItem(
                    sortKey: 0,
                    entity: 0,
                    drawPass: BlockDrawPass(pipeline: pipelines.intermediate, sampler: pipelines.sampler, texture: texture, block: block),
                    primitiveType: .quad,
                    renderPipeline: uiPipelines,
                    drawData: UIDrawData()
                ))
            }
        }
    }

    private struct Frame {
        var image: Image
    }

    private func isClose(_ left: Color, _ right: Color) -> Bool {
        abs(left.red - right.red) < 0.02 && abs(left.green - right.green) < 0.02 && abs(left.blue - right.blue) < 0.02
    }

    private func expectColor(_ actual: Color, _ expected: Color, _ message: String, allowing others: [Color] = [], sourceLocation: SourceLocation = #_sourceLocation) {
        let matches = isClose(actual, expected) || others.contains { isClose(actual, $0) }
        #expect(matches, "\(message): got \(actual), expected \(expected)", sourceLocation: sourceLocation)
    }

    private func render(output: SizeInt, resolution: SizeInt?, mode: PixelPerfectSettings.ScaleMode = .integer, uiBlocks: [Rect] = []) async throws -> Frame {
        let backend: RenderBackendType = pixelPerfectSAGASmokeEnabled ? .saga : .metal
        unsafe RenderEngine.configurations.preferredBackend = backend
        try RenderEngine.setupRenderEngine()
        try #require(unsafe RenderEngine.shared.type == backend, "Requested GPU backend must be active.")
        let device = unsafe RenderEngine.shared.renderDevice
        let queue: (any MTLCommandQueue)?
        if pixelPerfectSAGASmokeEnabled {
            queue = nil
        } else {
            let nativeQueue = try #require(MetalInterop.commandQueue(for: device))
            queue = nativeQueue
        }

        let app = AppWorlds(main: World())
        app.insertResource(OffscreenRenderWorld())
            .insertResource(HandledEvents())
            .insertResource(PrimaryWindowId(windowId: RID()))
            .addPlugin(MainSchedulerPlugin())
            .addPlugin(TransformPlugin())
            .addPlugin(RenderWorldPlugin())
            .addPlugin(CameraPlugin())
            .addPlugin(AssetsPlugin(filePath: #filePath))
            .addPlugin(VisibilityPlugin())
            .addPlugin(SpritePlugin())
            .addPlugin(Core2DPlugin())
            .addPlugin(UpscalePlugin())
        if !uiBlocks.isEmpty {
            // No windows are created: the manager only has to exist for the UI systems.
            app.insertResource(WindowManagerResource(windowManager: UIWindowManager()))
            app.addPlugin(InputPlugin()).addPlugin(TextPlugin()).addPlugin(UIPlugin())
            app.addPlugin(InjectBlocksPlugin(blocks: uiBlocks))
        }
        try await app.build()

        let target = RenderTexture(size: output, scaleFactor: 1, format: .bgra8)
        var camera = Camera(renderTarget: target)
        camera.backgroundColor = scene
        if let resolution {
            camera.pixelPerfect = PixelPerfectSettings(resolution: resolution, scaleMode: mode, letterboxColor: letterbox)
        }
        _ = app.main.spawn("Camera", bundle: Camera2D(camera: camera))
        // Two one-unit sprites in opposite corners of the 8x6 picture: art pixel (0, 0) and art pixel (7, 5).
        app.main.spawn("Top left") {
            Sprite(tintColor: .red, size: Size(width: 1, height: 1))
            Transform(position: [-3.5, 2.5, 0])
        }
        app.main.spawn("Bottom right") {
            Sprite(tintColor: .green, size: Size(width: 1, height: 1))
            Transform(position: [3.5, -2.5, 0])
        }

        for _ in 0..<4 {
            try await app.update()
        }
        if let queue {
            let fence = try #require(queue.makeCommandBuffer())
            await withCheckedContinuation { continuation in
                fence.addCompletedHandler { _ in continuation.resume() }
                fence.commit()
            }
        }
        return Frame(image: try #require(try await device.readImage(from: target)))
    }
}
#endif
