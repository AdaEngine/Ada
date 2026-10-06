import AdaECS
@_spi(Internal) @testable import AdaInput
@testable import AdaPlatform
@_spi(Internal) import AdaRender
@testable import AdaUI
import AdaUtils
import Math
import Testing

@Suite("UI scene picking blocking")
@MainActor
struct UIScenePickingBlockingTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test("Window routing blocks a UI press and its captured release outside the view")
    func uiGestureBlocking() async throws {
        let window = UIWindow(frame: Rect(x: 0, y: 0, width: 100, height: 100))
        let view = UIView(frame: Rect(x: 0, y: 0, width: 30, height: 30))
        window.addSubview(view)
        window.layoutSubviews()
        let world = makeWorld()
        let begin = mouse(window.id, at: [10, 10], phase: .began)
        world.getRefResource(Input.self).pendingEventsPool = [begin]
        await world.runScheduler(.preUpdate)
        #expect(world.getResource(Input.self)?.isScenePickingBlocked(eventID: begin.id) == true)
        let end = mouse(window.id, at: [90, 90], phase: .ended)
        world.getRefResource(Input.self).wrappedValue.removeEvents()
        world.getRefResource(Input.self).pendingEventsPool = [end]
        await world.runScheduler(.preUpdate)
        #expect(world.getResource(Input.self)?.isScenePickingBlocked(eventID: end.id) == true)
    }

    @Test("Scene fallback and disabled UI do not block picking")
    func sceneFallback() async throws {
        let window = UIWindow(frame: Rect(x: 0, y: 0, width: 100, height: 100))
        let view = UIView(frame: Rect(x: 0, y: 0, width: 100, height: 100))
        view.isInteractionEnabled = false
        window.addSubview(view)
        window.layoutSubviews()
        let world = makeWorld()
        let event = mouse(window.id, at: [50, 50], phase: .began)
        world.getRefResource(Input.self).pendingEventsPool = [event]
        await world.runScheduler(.preUpdate)
        #expect(world.getResource(Input.self)?.isScenePickingBlocked(eventID: event.id) == false)
        #expect(world.getResource(Input.self)?.isScenePickingBlocked(pointer: .mouse(window: window.id)) == false)
    }

    @Test("An overlay appearing over a stationary mouse blocks it next frame")
    func stationaryOverlay() async throws {
        let window = UIWindow(frame: Rect(x: 0, y: 0, width: 100, height: 100))
        let world = makeWorld()
        world.getRefResource(Input.self).pendingEventsPool = [mouse(window.id, at: [50, 50], phase: .changed, button: .none)]
        await world.runScheduler(.preUpdate)
        #expect(world.getResource(Input.self)?.isScenePickingBlocked(pointer: .mouse(window: window.id)) == false)
        let view = UIView(frame: Rect(x: 0, y: 0, width: 100, height: 100))
        window.addSubview(view)
        window.layoutSubviews()
        world.getRefResource(Input.self).wrappedValue.removeEvents()
        await world.runScheduler(.preUpdate)
        #expect(world.getResource(Input.self)?.isScenePickingBlocked(pointer: .mouse(window: window.id)) == true)
        view.isHidden = true
        await world.runScheduler(.preUpdate)
        #expect(world.getResource(Input.self)?.isScenePickingBlocked(pointer: .mouse(window: window.id)) == false)
    }

    private func makeWorld() -> World {
        let world = World()
        world.insertResource(Input(gameControllerEngine: nil))
        world.insertResource(DeltaTime(deltaTime: 0.016))
        world.insertResource(WindowManagerResource(windowManager: UIWindowManager.shared))
        world.insertResource(UIWindowPendingDrawViews())
        world.insertResource(UIContextPendingDraw())
        world.insertResource(UIRedrawRequest())
        world.addSystem(InputEventParseSystem.self, on: .preUpdate)
        world.addSystem(UpdateWindowManagerSystem.self, on: .preUpdate)
        return world
    }

    private func mouse(_ window: RID, at point: Point, phase: MouseEvent.Phase, button: MouseButton = .left) -> MouseEvent {
        MouseEvent(window: window, button: button, mousePosition: point, phase: phase, modifierKeys: [], time: 0)
    }
}
