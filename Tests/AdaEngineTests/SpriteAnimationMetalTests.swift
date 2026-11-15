#if os(macOS)
@_spi(Internal) import AdaApp
import AdaAssets
@testable import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
@testable import AdaSprite
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

/// Plays an animation through the real systems and checks what the GPU draws on every frame.
/// Run alone in a fresh process, like the other Metal suites:
/// `ADAENGINE_SPRITE_ANIM_METAL_SMOKE=1 swift test --filter SpriteAnimationMetalTests`
@Suite("Sprite animation GPU rendering", .serialized)
@MainActor
struct SpriteAnimationMetalTests {
    private static let targetSize = 64

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_SPRITE_ANIM_METAL_SMOKE"] == "1"))
    func gridFramesReachTheScreen() async throws {
        try setupMetal()
        let clip = SpriteAnimationClip.row("run", row: 0, columns: 0..<4, framesPerSecond: 10)
        let set = try SpriteAnimationSet(
            descriptor: SpriteAnimationSetDescriptor(image: "sheet.png", cellSize: SizeInt(width: 4, height: 4), filter: .nearest, clips: [clip]),
            image: Self.sheet(widths: [4, 4, 4, 4])
        )
        for mode in [SpriteRenderingMode.automatic, .batched] {
            let colors = try await play(set, frames: 5, mode: mode)
            // 0.1 s per frame, then the loop wraps back to red.
            #expect(colors == [.red, .green, .blue, .yellow, .red], "mode \(mode)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_SPRITE_ANIM_METAL_SMOKE"] == "1"))
    func asepriteRegionsReachTheScreen() async throws {
        try setupMetal()
        // An Aseprite export whose frames have different widths, which a fixed grid cannot express.
        let widths = [2, 6, 3, 5]
        var x = 0
        var frames: [String] = []
        for (index, width) in widths.enumerated() {
            frames.append(#"{ "filename": "f \#(index)", "frame": { "x": \#(x), "y": 0, "w": \#(width), "h": 4 }, "duration": 100 }"#)
            x += width
        }
        let json = #"{ "frames": [\#(frames.joined(separator: ","))], "meta": { "image": "sheet.png", "frameTags": [ { "name": "go", "from": 0, "to": 3, "direction": "forward" } ] } }"#
        let sheet = try AsepriteSheet(data: Data(json.utf8))
        let set = try SpriteAnimationSet(descriptor: try sheet.descriptor(), image: Self.sheet(widths: widths))
        for mode in [SpriteRenderingMode.automatic, .batched] {
            let colors = try await play(set, frames: 4, mode: mode)
            #expect(colors == [.red, .green, .blue, .yellow], "mode \(mode)")
        }
    }

    // MARK: - Fixture

    /// Solid colour blocks left to right: red, green, blue, yellow, each `widths[i]` wide and four high.
    private static func sheet(widths: [Int]) -> Image {
        var image = Image(width: widths.reduce(0, +), height: 4, color: .black)
        var x = 0
        for (index, width) in widths.enumerated() {
            let color: Color = [.red, .green, .blue, .yellow][index]
            for column in x..<x + width {
                for y in 0..<4 { image.setPixel(in: [Float(column), Float(y)], color: color) }
            }
            x += width
        }
        return image
    }

    private func setupMetal() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .saga
            try RenderEngine.setupRenderEngine()
        }
        try #require(unsafe RenderEngine.shared.type == .saga, "SAGA Metal must be active; a headless fallback proves nothing.")
        Sprite.registerComponent()
        SpriteAnimator.registerComponent()
        Transform.registerComponent()
        GlobalTransform.registerComponent()
        Visibility.registerComponent()
        BoundingComponent.registerComponent()
        Camera.registerComponent()
        VisibleEntities.registerComponent()
    }

    /// Advances the main world by 0.1 s per frame and returns the centre pixel the GPU drew after each update.
    private func play(_ set: SpriteAnimationSet, frames: Int, mode: SpriteRenderingMode) async throws -> [Color] {
        let main = World()
        main.insertResource(HandledEvents())
        main.addSystem(SpriteAnimationSystem.self, on: .update)
        main.addSystem(TransformSystem.self, on: .postUpdate)
        main.addSystem(UpdateBoundingsSystem.self, on: .postUpdate)
        main.spawn {
            Sprite(size: Size(width: 32, height: 32))
            SpriteAnimator(animations: AssetHandle(set))
            Transform()
        }
        var colors: [Color] = []
        for frame in 0..<frames {
            // The first update shows frame 0 before any time passes.
            await main.runScheduler(.update, deltaTime: frame == 0 ? 0 : 0.1)
            await main.runScheduler(.postUpdate)
            colors.append(try await draw(main, mode: mode))
        }
        return colors
    }

    private func draw(_ main: World, mode: SpriteRenderingMode) async throws -> Color {
        let device = unsafe RenderEngine.shared.renderDevice
        let world = World()
        world.insertResource(MainWorld(world: main))
        world.insertResource(ExtractedSprites())
        world.insertResource(AdditionalExtractedSprites())
        world.insertResource(RenderItems<Transparent2DRenderItem>())
        world.insertResource(SortedRenderItems<Transparent2DRenderItem>())
        world.insertResource(SpriteDrawPass())
        world.insertResource(SpriteBatches())
        var spriteData = SpriteDrawData.defaultValue
        spriteData.renderingMode = mode
        world.insertResource(spriteData)
        world.insertResource(RenderPipelines(configurator: SpriteRenderPipeline()))
        world.insertResource(RenderDeviceHandler(renderDevice: device))
        world.addSystem(ExtractSpriteSystem.self, on: .extract)
        world.addSystem(PrepareSpritesSystem.self, on: .preUpdate)
        world.addSystem(Transparent2DBatchingSystem.self, on: .batching)
        world.addSystem(SpriteRenderSystem.self, on: .update)
        let view = world.spawn {
            Camera()
            VisibleEntities(entityIds: Set(main.getEntities().map(\.id)))
        }
        await world.runScheduler(.extract)
        await world.runScheduler(.preUpdate)
        await world.runScheduler(.batching)
        await world.runScheduler(.update)

        let size = Self.targetSize
        let target = RenderTexture(size: SizeInt(width: size, height: size), scaleFactor: 1, format: .bgra8)
        let commandBuffer = device.createCommandQueue().makeCommandBuffer()
        let encoder = commandBuffer.beginRenderPass(RenderPassDescriptor(colorAttachments: [
            .init(texture: target, operation: OperationDescriptor(loadAction: .clear, storeAction: .store), clearColor: .black)
        ]))
        let projection = Transform3D(scale: [Float(2) / Float(size), Float(2) / Float(size), 0.01])
        encoder.setVertexBuffer(GlobalViewUniform(projectionMatrix: projection, viewProjectionMatrix: projection), slot: GlobalBufferIndex.viewUniform)
        encoder.setViewport(Rect(x: 0, y: 0, width: Float(size), height: Float(size)))
        let items = try #require(world.getResource(SortedRenderItems<Transparent2DRenderItem>.self))
        try items.items.render(with: encoder, world: world, view: view)
        encoder.endRenderPass()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { continuation.resume() }
            commandBuffer.commit()
        }
        let result = try #require(try await device.readImage(from: target))
        // Pixels well outside the sprite stay clear, so the colour at the centre really came from the sprite.
        #expect(result.getPixel(x: 2, y: 2) == .black)
        return result.getPixel(x: size / 2, y: size / 2)
    }
}
#endif
