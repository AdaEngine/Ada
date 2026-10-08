import Foundation

/// One named gameplay action. Any binding may activate it; the strongest binding wins.
public struct InputAction: Codable, Equatable, Sendable {
    public var name: String
    public var bindings: [InputBinding]
    /// Analog values at or below this threshold are ignored. Must be in 0..<1.
    public var deadZone: Float

    public init(name: String, bindings: [InputBinding] = [], deadZone: Float = 0.2) {
        self.name = name
        self.bindings = bindings
        self.deadZone = deadZone
    }

    /// Validates names, duplicate bindings and analog thresholds before installing or saving a map.
    public static func validate(_ actions: [Self]) throws {
        var names = Set<String>()
        for action in actions {
            guard
                !action.name.isEmpty,
                action.name == action.name.trimmingCharacters(in: .whitespacesAndNewlines),
                !action.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw InputActionError.invalid("Action names must be nonempty and have no surrounding whitespace or control characters.")
            }
            guard names.insert(action.name).inserted else {
                throw InputActionError.invalid("Action '\(action.name)' already exists.")
            }
            guard action.deadZone.isFinite, (0..<1).contains(action.deadZone) else {
                throw InputActionError.invalid("Dead zone for '\(action.name)' must be between 0 and 1 (exclusive).")
            }
            guard Set(action.bindings).count == action.bindings.count else {
                throw InputActionError.invalid("Action '\(action.name)' contains duplicate bindings.")
            }
            for binding in action.bindings {
                switch binding {
                case .key(.none),
                    .mouseButton(.none),
                    .mouseButton(.scrollWheel),
                    .gamepadButton(.unknown),
                    .gamepadAxis(.unknown, _):
                    throw InputActionError.invalid("Action '\(action.name)' contains an unsupported input.")
                default: break
                }
            }
        }
    }
}

public enum InputActionError: Error, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}

/// A physical source for a gameplay action. Gamepad bindings match any connected controller.
public enum InputBinding: Codable, Hashable, Sendable {
    case key(KeyCode)
    case mouseButton(MouseButton)
    /// Vertical wheel input, active for the frame in which scrolling occurred.
    case mouseScroll(InputAxisDirection)
    case mouseMotion
    case gamepadButton(GamepadButton)
    case gamepadAxis(GamepadAxis, InputAxisDirection)
    /// Held while at least one finger is touching the screen.
    case touch
    /// A one-frame pulse for a touch lifecycle event.
    case touchEvent(InputTouchPhase)
}

public enum InputAxisDirection: String, Codable, CaseIterable, Sendable {
    case negative
    case positive
}

public enum InputTouchPhase: String, Codable, CaseIterable, Sendable {
    case began
    case moved
    case ended
    case cancelled
}

extension Input {
    /// Replaces the action map and clears action transitions. Raw device state is preserved.
    public mutating func setInputActions(_ actions: [InputAction]) throws {
        try InputAction.validate(actions)
        actionDefinitions = actions
        actionStrengths.removeAll(keepingCapacity: true)
        justPressedActions.removeAll(keepingCapacity: true)
        justReleasedActions.removeAll(keepingCapacity: true)
    }

    /// True while at least one binding is active. Unknown names return false.
    public func isActionPressed(_ name: String) -> Bool { getActionStrength(name) > 0 }
    /// True if the action became active during this frame, including a completed short tap.
    public func isActionJustPressed(_ name: String) -> Bool { justPressedActions.contains(name) }
    /// True if the last active binding was released during this frame.
    public func isActionJustReleased(_ name: String) -> Bool { justReleasedActions.contains(name) }

    /// Returns 0...1 after the dead zone. Unknown actions return zero.
    public func getActionStrength(_ name: String) -> Float { actionStrengths[name, default: 0] }

    mutating func beginActionFrame() {
        justPressedActions.removeAll(keepingCapacity: true)
        justReleasedActions.removeAll(keepingCapacity: true)
        actionScrollDirections.removeAll(keepingCapacity: true)
        actionMouseMoved = false
        actionTouchPhases.removeAll(keepingCapacity: true)
        updateActionStates()
    }

    // Called after each event to preserve press + release transitions within a single frame.
    mutating func updateActionStates() {
        for action in actionDefinitions {
            var strength: Float = 0
            for binding in action.bindings {
                strength = max(strength, bindingStrength(binding, deadZone: action.deadZone))
            }
            let wasPressed = actionStrengths[action.name, default: 0] > 0
            if !wasPressed, strength > 0 {
                justPressedActions.insert(action.name)
            }
            if wasPressed, strength == 0 {
                justReleasedActions.insert(action.name)
            }
            actionStrengths[action.name] = strength
        }
    }

    private func bindingStrength(_ binding: InputBinding, deadZone: Float) -> Float {
        switch binding {
        case let .key(key): return isKeyPressed(key) ? 1 : 0
        case let .mouseButton(button): return isMouseButtonPressed(button) ? 1 : 0
        case let .mouseScroll(direction): return actionScrollDirections.contains(direction) ? 1 : 0
        case .mouseMotion: return actionMouseMoved ? 1 : 0
        case .touch: return touches.isEmpty ? 0 : 1
        case let .touchEvent(phase): return actionTouchPhases.contains(phase) ? 1 : 0
        case let .gamepadButton(button):
            return gamepads.values.contains { $0.isGamepadButtonPressed(button) } ? 1 : 0
        case let .gamepadAxis(axis, direction):
            var strength: Float = 0
            for gamepad in gamepads.values {
                let value = gamepad.getAxisValue(axis) * (direction == .positive ? 1 : -1)
                if value.isFinite, value > deadZone {
                    strength = max(strength, min(1, (value - deadZone) / (1 - deadZone)))
                }
            }
            return strength
        }
    }
}
