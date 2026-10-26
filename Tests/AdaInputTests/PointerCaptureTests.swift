import AdaApp
import AdaECS
@_spi(Internal) @testable import AdaInput
import AdaUtils
import Foundation
import Math
import Testing

@MainActor
@Suite("Pointer capture and relative input")
struct PointerCaptureTests {
    @Test func rawMotionAccumulatesWhileTheCursorPositionStaysFixed() async throws {
        let world = World()
        world.insertResource(Input(gameControllerEngine: nil))
        world.addSystem(InputEventParseSystem.self)
        let input = world.getRefResource(Input.self)
        for delta: Vector2 in [[3, -2], [4, 5]] {
            input.wrappedValue.receiveEvent(MouseEvent(window: .empty, button: .none, motionDelta: delta,
                mousePosition: [50, 50], phase: .changed, modifierKeys: [], time: 0))
        }
        await world.runScheduler(.update)
        #expect(input.wrappedValue.getMouseDelta() == [7, 3])
        input.wrappedValue.removeEvents()
        await world.runScheduler(.update)
        #expect(input.wrappedValue.getMouseDelta() == .zero)
    }

    @Test func positionFallbackDoesNotJoinDifferentWindowsOrAcceptNonfiniteDeltas() async {
        let world = World()
        world.insertResource(Input(gameControllerEngine: nil))
        world.addSystem(InputEventParseSystem.self)
        let input = world.getRefResource(Input.self)
        let first = RID(); let second = RID()
        let locations: [(RID, Point)] = [(first, [10, 10]), (second, [100, 100]), (first, [12, 13])]
        for (window, point) in locations {
            input.wrappedValue.receiveEvent(MouseEvent(window: window, button: .none,
                mousePosition: point, phase: .changed, modifierKeys: [], time: 0))
        }
        input.wrappedValue.receiveEvent(MouseEvent(window: first, button: .none, motionDelta: [.nan, 1],
            mousePosition: [12, 13], phase: .changed, modifierKeys: [], time: 0))
        await world.runScheduler(.update)
        #expect(input.wrappedValue.getMouseDelta() == [2, 3])
    }

    @Test func worldLeasesAreIndependentAndPluginTeardownReleasesItsLease() {
        let driver = Driver()
        let first = AppWorlds(main: World())
        let second = AppWorlds(main: World())
        let plugin = InputPlugin(actions: [])
        plugin.setup(in: first)
        plugin.setup(in: second)
        let a = first.main.getRefResource(Input.self)
        let b = second.main.getRefResource(Input.self)
        a.wrappedValue.attachPointerDriver(driver)
        b.wrappedValue.attachPointerDriver(driver)
        a.wrappedValue.setMouseMode(.captured)
        #expect(a.wrappedValue.getMouseMode() == .captured)
        b.wrappedValue.setMouseMode(.visible)
        #expect(a.wrappedValue.getMouseMode() == .captured)
        b.wrappedValue.setMouseMode(.captured)
        #expect(a.wrappedValue.getMouseMode() == .visible)
        plugin.destroy(for: first)
        #expect(b.wrappedValue.getMouseMode() == .captured)
        plugin.destroy(for: second)
        #expect(b.wrappedValue.getMouseMode() == .visible)
    }

    @Test func captureStatusIsTransient() throws {
        var control = MouseCaptureComponent(isRequested: true)
        control.isCaptured = true
        let decoded = try JSONDecoder().decode(MouseCaptureComponent.self, from: JSONEncoder().encode(control))
        #expect(decoded.isRequested && !decoded.isCaptured)
    }

    @MainActor
    private final class Driver: InputPointerDriver {
        var owner: UUID?
        func requestMouseMode(_: Input.MouseMode, owner: UUID, window _: RID?) { self.owner = owner }
        func releaseMouseMode(owner: UUID) { if self.owner == owner { self.owner = nil } }
        func mouseMode(owner: UUID) -> Input.MouseMode { self.owner == owner ? .captured : .visible }
    }
}
