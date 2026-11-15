#if os(macOS)
@_spi(Internal) import AdaApp
import AdaAssets
@testable import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
@testable import AdaSprite
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

/// Draws a scene through a camera driven by Camera2DController and reads the pixels back.
/// Run alone in a fresh process, like the other Metal suites:
/// `ADAENGINE_CAMERA2D_METAL_SMOKE=1 swift test --filter Camera2DMetalTests`
@Suite("Camera2D GPU rendering", .serialized)
@MainActor
struct Camera2DMetalTests {
    private static let size = SizeInt(width: 128, height: 64)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_CAMERA2D_METAL_SMOKE"] == "1"))
    func followedSpriteStaysCenteredAtZoom() async throws {
        try setupMetal()
        let main = World()
        main.insertResource(HandledEvents())
        main.addSystem(CameraSystem.self, on: .preUpdate)
        main.addSystem(TransformSystem.self, on: .postUpdate)
        main.addSystem(ChildTransformSystem.self, on: .postUpdate)
        main.addSystem(UpdateBoundingsSystem.self, on: .postUpdate)
        main.addSystem(Camera2DControllerSystem.self, on: .postUpdate)

        let hero = main.spawn {
            Sprite(tintColor: .red, size: Size(width: 16, height: 16))
            Transform(position: [300, -120, 0])
            CameraTarget2D(group: "hero")
        }
        let neighbour = main.spawn {
            Sprite(tintColor: .blue, size: Size(width: 16, height: 16))
            Transform(position: [324, -120, 0])
        }
        var controller = Camera2DController(targetGroup: "hero", zoom: 2)
        controller.limitsEnabled = false
        let camera = main.spawn {
            Camera(renderTarget: RenderTexture(size: Self.size, scaleFactor: 1, format: .bgra8))
            Transform()
            controller
        }

        func render(_ delta: AdaUtils.TimeInterval, move: () -> Void = {}) async throws -> Image {
            await main.runScheduler(.preUpdate, deltaTime: delta)
            move()
            await main.runScheduler(.postUpdate, deltaTime: delta)
            return try await draw(main, camera: camera)
        }

        // Zoom 2 doubles everything: the hero (16 units) covers 32 pixels around the centre, the neighbour sits 48 pixels right.
        var image = try await render(0)
        #expect(image.getPixel(x: 64, y: 32) == .red)
        #expect(image.getPixel(x: 112, y: 32) == .blue)
        #expect(image.getPixel(x: 48 - 2, y: 32) == .black)
        #expect(image.getPixel(x: 2, y: 2) == .black)

        // Both move in the same frame. A camera a frame behind would show the hero 80 pixels off centre.
        image = try await render(1.0 / 60) {
            hero.components[Transform.self]?.position = [340, -100, 0]
            neighbour.components[Transform.self]?.position = [364, -100, 0]
        }
        #expect(image.getPixel(x: 64, y: 32) == .red)
        #expect(image.getPixel(x: 112, y: 32) == .blue)
        #expect(image.getPixel(x: 80 + 2, y: 32) == .black) // right edge of the hero is at 80, just before the neighbour starts at 96

        // Zooming back out to 1 halves their size and spacing: the neighbour is now 24 pixels right of the centre.
        camera.components[Camera2DController.self]?.zoom = 1
        image = try await render(1.0 / 60)
        #expect(image.getPixel(x: 64, y: 32) == .red)
        #expect(image.getPixel(x: 88, y: 32) == .blue)
        #expect(image.getPixel(x: 112, y: 32) == .black)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_CAMERA2D_METAL_SMOKE"] == "1"))
    func limitsAndShakeMoveThePicture() async throws {
        try setupMetal()
        let main = World()
        main.insertResource(HandledEvents())
        main.addSystem(CameraSystem.self, on: .preUpdate)
        main.addSystem(TransformSystem.self, on: .postUpdate)
        main.addSystem(ChildTransformSystem.self, on: .postUpdate)
        main.addSystem(UpdateBoundingsSystem.self, on: .postUpdate)
        main.addSystem(Camera2DControllerSystem.self, on: .postUpdate)

        // A 32x32 marker at the world corner (0, 0) of limits that start at (0, 0).
        _ = main.spawn {
            Sprite(tintColor: .green, size: Size(width: 32, height: 32), anchor: .bottomLeft)
            Transform(position: [0, 0, 0])
        }
        _ = main.spawn { Transform(position: [-500, -500, 0]); CameraTarget2D() }
        var controller = Camera2DController()
        controller.limitsEnabled = true
        controller.limitMin = Vector2(0, 0)
        controller.limitMax = Vector2(400, 300)
        controller.shakeMaxOffset = Vector2(20, 0)
        let camera = main.spawn {
            Camera(renderTarget: RenderTexture(size: Self.size, scaleFactor: 1, format: .bgra8))
            Transform()
            controller
        }

        await main.runScheduler(.preUpdate, deltaTime: 0)
        await main.runScheduler(.postUpdate, deltaTime: 0)
        // The target is far outside, but the view stays inside the limits: its bottom-left corner is the world origin.
        var image = try await draw(main, camera: camera)
        #expect(image.getPixel(x: 16, y: 64 - 16) == .green)
        #expect(image.getPixel(x: 40, y: 64 - 16) == .black)
        #expect(image.getPixel(x: 16, y: 64 - 40) == .black)

        // Full trauma pushes the picture sideways by up to 20 world units, so the marker leaves its place.
        camera.components[Camera2DController.self]?.addTrauma(1)
        var moved = false
        for step in 0..<20 {
            await main.runScheduler(.preUpdate, deltaTime: 1.0 / 60)
            await main.runScheduler(.postUpdate, deltaTime: 1.0 / 60)
            image = try await draw(main, camera: camera)
            if step > 2, image.getPixel(x: 16, y: 64 - 16) != .green || image.getPixel(x: 40, y: 64 - 16) == .green { moved = true }
        }
        #expect(moved)
    }

    // MARK: - Fixture

    private func setupMetal() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .saga
            try RenderEngine.setupRenderEngine()
        }
        try #require(unsafe RenderEngine.shared.type == .saga, "SAGA Metal must be active; a headless fallback proves nothing.")
        Sprite.registerComponent()
        Transform.registerComponent()
        GlobalTransform.registerComponent()
        Visibility.registerComponent()
        BoundingComponent.registerComponent()
        Camera.registerComponent()
        VisibleEntities.registerComponent()
        Camera2DController.registerComponent()
        CameraTarget2D.registerComponent()
    }

    /// Draws every sprite with the camera's own view uniform, exactly as extraction would hand it to the renderer.
    private func draw(_ main: World, camera: Entity) async throws -> Image {
        let device = unsafe RenderEngine.shared.renderDevice
        let uniform = try #require(camera.components[GlobalViewUniform.self])
        let world = World()
        world.insertResource(MainWorld(world: main))
        world.insertResource(ExtractedSprites())
        world.insertResource(AdditionalExtractedSprites())
        world.insertResource(RenderItems<Transparent2DRenderItem>())
        world.insertResource(SortedRenderItems<Transparent2DRenderItem>())
        world.insertResource(SpriteDrawPass())
        world.insertResource(SpriteBatches())
        world.insertResource(SpriteDrawData.defaultValue)
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

        let target = RenderTexture(size: Self.size, scaleFactor: 1, format: .bgra8)
        let commandBuffer = device.createCommandQueue().makeCommandBuffer()
        let encoder = commandBuffer.beginRenderPass(RenderPassDescriptor(colorAttachments: [
            .init(texture: target, operation: OperationDescriptor(loadAction: .clear, storeAction: .store), clearColor: .black)
        ]))
        encoder.setVertexBuffer(uniform, slot: GlobalBufferIndex.viewUniform)
        encoder.setViewport(Rect(x: 0, y: 0, width: Float(Self.size.width), height: Float(Self.size.height)))
        let items = try #require(world.getResource(SortedRenderItems<Transparent2DRenderItem>.self))
        try items.items.render(with: encoder, world: world, view: view)
        encoder.endRenderPass()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { continuation.resume() }
            commandBuffer.commit()
        }
        return try #require(try await device.readImage(from: target))
    }
}
#endif
