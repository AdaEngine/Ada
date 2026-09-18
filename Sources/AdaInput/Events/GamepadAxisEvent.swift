//
//  GamepadAxisEvent.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

import AdaUtils

/// An event that represents a change in a gamepad's analog axis value.
///
/// This event is dispatched when an analog stick or trigger on a connected gamepad moves.
public struct GamepadAxisEvent: InputEvent {
    public let id: AdaUtils.RID = RID()
    public var window: AdaUtils.RID
    public var time: AdaUtils.TimeInterval

    /// The unique identifier of the gamepad that triggered the event.
    /// Gamepad IDs are typically assigned by the system.
    public let gamepadId: Int

    /// The specific `GamepadAxis` that changed its value.
    public let axis: GamepadAxis

    /// The new value of the axis, typically ranging from -1.0 to 1.0 for sticks,
    /// and 0.0 to 1.0 for triggers.
    public let value: Float

    public init(gamepadId: Int, axis: GamepadAxis, value: Float, window: RID, time: TimeInterval) {
        self.gamepadId = gamepadId
        self.axis = axis
        self.value = value
        self.window = window
        self.time = time
    }
}
