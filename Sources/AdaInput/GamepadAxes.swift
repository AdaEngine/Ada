//
//  GamepadAxes.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

/// Represents the analog axes on a gamepad, such as sticks and triggers.
///
/// These cases cover common axes found on most modern gamepads.
/// Values are typically normalized between -1.0 and 1.0 for sticks, and 0.0 to 1.0 for triggers.
public enum GamepadAxis: String, Codable, CaseIterable, Hashable, Sendable {
    /// The horizontal (X) axis of the left analog stick.
    /// Typically, negative values represent left, and positive values represent right.
    case leftStickX
    /// The vertical (Y) axis of the left analog stick.
    /// Typically, negative values represent up, and positive values represent down (this can vary).
    case leftStickY

    /// The horizontal (X) axis of the right analog stick.
    /// Typically, negative values represent left, and positive values represent right.
    case rightStickX
    /// The vertical (Y) axis of the right analog stick.
    /// Typically, negative values represent up, and positive values represent down (this can vary).
    case rightStickY

    /// The analog input from the left trigger.
    /// Typically ranges from 0.0 (not pressed) to 1.0 (fully pressed).
    case leftTrigger
    /// The analog input from the right trigger.
    /// Typically ranges from 0.0 (not pressed) to 1.0 (fully pressed).
    case rightTrigger

    /// Represents an unknown or unmapped axis.
    case unknown
}
