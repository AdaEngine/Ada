//
//  GamepadConnectionEvent.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

import AdaUtils

/// An event that represents a gamepad connection or disconnection.
///
/// This event is dispatched when a gamepad is connected to or disconnected from the system.
public struct GamepadConnectionEvent: InputEvent {
    public let id: RID = RID()

    public let window: RID

    public let time: TimeInterval

    /// The unique identifier of the gamepad that triggered the event.
    /// Gamepad IDs are typically assigned by the system.
    public let gamepadId: Int

    public let gamepadInfo: GamepadInfo?

    /// A Boolean value indicating whether the gamepad was connected (`true`) or disconnected (`false`).
    public let isConnected: Bool

    public init(
        gamepadId: Int,
        isConnected: Bool,
        gamepadInfo: GamepadInfo?,
        window: RID,
        time: TimeInterval
    ) {
        self.gamepadId = gamepadId
        self.isConnected = isConnected
        self.gamepadInfo = gamepadInfo
        self.window = window
        self.time = time
    }
}
