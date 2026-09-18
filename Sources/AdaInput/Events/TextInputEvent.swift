//
//  TextInputEvent.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 06.02.2026.
//

import AdaUtils

/// An object that contains information about text input event.
/// This event is generated from software keyboard input (iOS) or IME input.
public struct TextInputEvent: InputEvent {
    public enum Action: UInt8, Hashable, Sendable {
        /// Text was inserted
        case insert
        /// Backspace/delete was pressed
        case deleteBackward
    }

    public var id: RID = RID()

    /// The text that was entered. Empty for deleteBackward action.
    public let text: String

    /// The action type (insert or delete)
    public let action: Action

    /// The window that received the input
    public let window: RID

    /// The timestamp of the event
    public var time: TimeInterval

    public init(
        window: RID,
        text: String,
        action: Action,
        time: TimeInterval
    ) {
        self.text = text
        self.action = action
        self.window = window
        self.time = time
    }
}
