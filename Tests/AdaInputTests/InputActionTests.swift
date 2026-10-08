import AdaApp
import AdaECS
@_spi(Internal) @testable import AdaInput
import AdaUtils
import Foundation
import Math
import Testing

@Suite("Input Actions")
@MainActor
struct InputActionTests {
    private func makeWorld(_ actions: [InputAction]) throws -> World {
        let world = World()
        var input = Input(gameControllerEngine: nil)
        try input.setInputActions(actions)
        world.insertResource(input)
        world.addSystem(InputEventParseSystem.self)
        return world
    }

    private func frame(_ world: World, events: [any InputEvent] = []) async throws -> Input {
        let input = world.getRefResource(Input.self)
        input.wrappedValue.removeEvents()
        input.wrappedValue.pendingEventsPool = events
        await world.runScheduler(.update)
        return try #require(world.getResource(Input.self))
    }

    private func key(_ code: KeyCode, _ status: KeyEvent.Status) -> KeyEvent {
        KeyEvent(window: .empty, keyCode: code, modifiers: [], status: status, time: 0, isRepeated: false)
    }

    @Test func combinesBindingsAndPreservesSameFrameTap() async throws {
        let world = try makeWorld([InputAction(name: "Jump", bindings: [.key(.space), .mouseButton(.left)])])
        var input = try await frame(world, events: [key(.space, .down)])
        #expect(input.isActionPressed("Jump") && input.isActionJustPressed("Jump"))
        input = try await frame(world)
        #expect(input.isActionPressed("Jump") && !input.isActionJustPressed("Jump"))
        let down = MouseEvent(window: .empty, button: .left, mousePosition: .zero, phase: .began, modifierKeys: [], time: 0)
        input = try await frame(world, events: [down, key(.space, .up)])
        #expect(input.isActionPressed("Jump") && !input.isActionJustReleased("Jump"))
        let up = MouseEvent(window: .empty, button: .left, mousePosition: .zero, phase: .ended, modifierKeys: [], time: 0)
        input = try await frame(world, events: [up])
        #expect(!input.isActionPressed("Jump") && input.isActionJustReleased("Jump"))
        input = try await frame(world, events: [key(.space, .down), key(.space, .up)])
        #expect(!input.isActionPressed("Jump"))
        #expect(input.isActionJustPressed("Jump") && input.isActionJustReleased("Jump"))
        #expect(input.getActionStrength("Missing") == 0)
    }

    @Test func gamepadDirectionDeadZoneAndDisconnect() async throws {
        let world = try makeWorld([
            InputAction(name: "Left", bindings: [.gamepadAxis(.leftStickX, .negative)]),
            InputAction(name: "Jump", bindings: [.gamepadButton(.a)])
        ])
        let connect = GamepadConnectionEvent(gamepadId: 1, isConnected: true, gamepadInfo: nil, window: .empty, time: 0)
        let axis = GamepadAxisEvent(gamepadId: 1, axis: .leftStickX, value: -0.6, window: .empty, time: 0)
        let button = GamepadButtonEvent(gamepadId: 1, button: .a, isPressed: true, pressure: 1, window: .empty, time: 0)
        var input = try await frame(world, events: [connect, axis, button])
        #expect(abs(input.getActionStrength("Left") - 0.5) < 0.001)
        #expect(input.isActionPressed("Jump"))
        input = try await frame(world, events: [GamepadAxisEvent(gamepadId: 1, axis: .leftStickX, value: 0.8, window: .empty, time: 0)])
        #expect(input.isActionJustReleased("Left"))
        input = try await frame(world, events: [GamepadAxisEvent(gamepadId: 1, axis: .leftStickX, value: -0.1, window: .empty, time: 0)])
        #expect(!input.isActionPressed("Left"))
        input = try await frame(world, events: [GamepadConnectionEvent(gamepadId: 1, isConnected: false, gamepadInfo: nil, window: .empty, time: 0)])
        #expect(input.isActionJustReleased("Jump"))
    }

    @Test func touchHoldsAcrossFramesAndTracksEveryContact() async throws {
        let world = try makeWorld([
            InputAction(name: "Touch", bindings: [.touch]),
            InputAction(name: "Begin", bindings: [.touchEvent(.began)])
        ])
        let first = RID(), second = RID()
        func touch(_ id: RID, _ phase: TouchEvent.Phase) -> TouchEvent {
            TouchEvent(window: .empty, location: .zero, phase: phase, time: 0, contactID: id)
        }
        var input = try await frame(world, events: [touch(first, .began), touch(second, .began)])
        #expect(input.isActionJustPressed("Touch") && input.isActionPressed("Begin"))
        input = try await frame(world)
        #expect(input.isActionPressed("Touch") && !input.isActionPressed("Begin"))
        input = try await frame(world, events: [touch(first, .ended), touch(second, .moved)])
        #expect(input.isActionPressed("Touch") && input.getTouches().count == 1)
        input = try await frame(world, events: [touch(second, .cancelled)])
        #expect(input.isActionJustReleased("Touch") && input.getTouches().isEmpty)
    }

    @Test func scrollIsAFramePulseAndMapReplacementClearsOldNames() async throws {
        let world = try makeWorld([InputAction(name: "Scroll", bindings: [.mouseScroll(.positive)])])
        var input = try await frame(world, events: [MouseEvent(
            window: .empty, button: .scrollWheel, scrollDelta: [0, 2], mousePosition: .zero,
            phase: .changed, modifierKeys: [], time: 0
        )])
        #expect(input.isActionJustPressed("Scroll"))
        input = try await frame(world)
        #expect(!input.isActionPressed("Scroll") && input.isActionJustReleased("Scroll"))
        try input.setInputActions([])
        #expect(!input.isActionJustReleased("Scroll"))
    }

    @Test func validatesAndRoundTripsEveryBinding() throws {
        let actions = [InputAction(name: "All", bindings: [
            .key(.space), .mouseButton(.left), .mouseMotion, .mouseScroll(.negative),
            .gamepadButton(.a), .gamepadAxis(.rightTrigger, .positive), .touch, .touchEvent(.cancelled)
        ])]
        let decoded = try JSONDecoder().decode([InputAction].self, from: JSONEncoder().encode(actions))
        #expect(decoded == actions)
        try InputAction.validate(decoded)
        #expect(throws: InputActionError.self) { try InputAction.validate(actions + actions) }
        #expect(throws: InputActionError.self) { try InputAction.validate([InputAction(name: " ")]) }
        #expect(throws: InputActionError.self) { try InputAction.validate([InputAction(name: "A", deadZone: 1)]) }
        #expect(throws: InputActionError.self) { try InputAction.validate([InputAction(name: "A", bindings: [.key(.a), .key(.a)])]) }
    }
}
