import AdaApp
import AdaECS
@_spi(Internal) @testable import AdaInput
import AdaRender
@testable import AdaUI
import Math
import Testing

@Suite("Window camera frame requests")
@MainActor
struct WindowCameraFrameRequestsTests {
    @Test("A late UI redraw requests only the windows that changed")
    func lateRedrawsStayScopedToTheirWindows() async throws {
        let manager = UIWindowManager()
        let frame = Rect(x: 0, y: 0, width: 320, height: 240)
        let first = UIWindow(frame: frame, configuration: .init(frame: frame), windowManager: manager)
        let second = UIWindow(frame: frame, configuration: .init(frame: frame), windowManager: manager)
        let world = World()
        world.insertResource(WindowManagerResource(windowManager: manager))
        world.insertResource(PrimaryWindowId(windowId: first.id))
        world.insertResource(Input(gameControllerEngine: nil))
        world.insertResource(DeltaTime(deltaTime: 0.016))
        world.addSystem(InputEventParseSystem.self, on: .preUpdate)
        UIPlugin().setup(in: AppWorlds(main: world))
        await world.runScheduler(.preUpdate)
        await world.runScheduler(.preUpdate)

        first.setNeedsDisplay()
        await world.runScheduler(.preUpdate)
        #expect(UIPlugin.collectLateFrameWork(in: world))
        let firstRequests = try #require(world.getResource(WindowFrameRequests.self))
        #expect(firstRequests.requestedWindowIDs == [first.id])

        world.getRefResource(UIRedrawRequest.self).wrappedValue.request(second.id)
        #expect(UIPlugin.collectLateFrameWork(in: world))
        let bothRequests = try #require(world.getResource(WindowFrameRequests.self))
        #expect(bothRequests.requestedWindowIDs == [first.id, second.id])
    }

    @Test("An active game camera keeps a window with an on-demand UI camera rendering")
    func gameCameraKeepsMixedWindowRendering() async throws {
        let manager = UIWindowManager()
        let frame = Rect(x: 0, y: 0, width: 320, height: 240)
        let window = UIWindow(frame: frame, configuration: .init(frame: frame), windowManager: manager)
        let world = World()
        world.insertResource(WindowManagerResource(windowManager: manager))
        world.insertResource(PrimaryWindowId(windowId: window.id))
        world.insertResource(Input(gameControllerEngine: nil))
        world.insertResource(DeltaTime(deltaTime: 0.016))
        world.addSystem(InputEventParseSystem.self, on: .preUpdate)
        UIPlugin().setup(in: AppWorlds(main: world))

        world.spawn {
            Camera(window: .primary)
            WindowRenderOnDemand()
        }
        // Allow the window to process its initial display request.
        await world.runScheduler(.preUpdate)
        await world.runScheduler(.preUpdate)
        let uiOnly = try #require(world.getResource(WindowFrameRequests.self))
        try #require(uiOnly.requestedWindowIDs.isEmpty)
        #expect(!uiOnly.shouldRender(window.id))

        var camera = Camera(window: .windowId(window.id))
        let gameCamera = world.spawn { camera }
        await world.runScheduler(.preUpdate)
        let mixed = try #require(world.getResource(WindowFrameRequests.self))
        try #require(mixed.requestedWindowIDs.isEmpty)
        #expect(mixed.shouldRender(window.id))
        #expect(mixed.expectsPresentation)

        camera.isActive = false
        gameCamera.components[Camera.self] = camera
        await world.runScheduler(.preUpdate)
        let inactive = try #require(world.getResource(WindowFrameRequests.self))
        #expect(!inactive.shouldRender(window.id))
    }
}
