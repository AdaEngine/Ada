//
//  GamepadButtons.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

/// Represents the physical buttons on a gamepad.
///
/// These cases cover common buttons found on most modern gamepads.
/// The specific mapping can vary depending on the controller and platform.
public enum GamepadButton: String, Codable, CaseIterable, Hashable, Sendable {
    /// The primary action button, often labeled 'A' on Xbox-style controllers or 'Cross' on PlayStation-style controllers.
    case a
    /// A secondary action button, often labeled 'B' on Xbox-style controllers or 'Circle' on PlayStation-style controllers.
    case b
    /// A tertiary action button, often labeled 'X' on Xbox-style controllers or 'Square' on PlayStation-style controllers.
    case x
    /// A quaternary action button, often labeled 'Y' on Xbox-style controllers or 'Triangle' on PlayStation-style controllers.
    case y

    /// The upper-left shoulder button (bumper), often labeled 'LB' or 'L1'.
    case leftShoulder
    /// The upper-right shoulder button (bumper), often labeled 'RB' or 'R1'.
    case rightShoulder

    /// The button associated with the left analog trigger, distinct from its analog axis value.
    /// Often labeled 'LT' or 'L2'. This represents the digital press of the trigger.
    case leftTriggerButton
    /// The button associated with the right analog trigger, distinct from its analog axis value.
    /// Often labeled 'RT' or 'R2'. This represents the digital press of the trigger.
    case rightTriggerButton

    /// The button activated by pressing down on the left analog stick, often labeled 'L3'.
    case leftStickButton
    /// The button activated by pressing down on the right analog stick, often labeled 'R3'.
    case rightStickButton

    /// The 'Up' button on the directional pad (D-pad).
    case dPadUp
    /// The 'Down' button on the directional pad (D-pad).
    case dPadDown
    /// The 'Left' button on the directional pad (D-pad).
    case dPadLeft
    /// The 'Right' button on the directional pad (D-pad).
    case dPadRight

    /// The 'Start' or 'Menu' button, used for pausing or accessing menus.
    case start
    /// The 'Select', 'Back', 'View', or 'Share' button, used for various secondary functions.
    case select

    /// Represents an unknown or unmapped button.
    case unknown
}
