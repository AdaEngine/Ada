//
//  KeyEvent.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

import AdaUtils

/// An object that contains information about keyboard event.
public struct KeyEvent: InputEvent {
    public enum Status: UInt8, Hashable, Sendable {
        case up
        case down
    }

    public var id: RID = RID()
    public let keyCode: KeyCode
    public let modifiers: KeyModifier
    public let status: Status
    public let isRepeated: Bool
    public let window: RID
    public var time: TimeInterval

    public init(
        window: RID,
        keyCode: KeyCode,
        modifiers: KeyModifier,
        status: Status,
        time: TimeInterval,
        isRepeated: Bool
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.status = status
        self.isRepeated = isRepeated
        self.window = window
        self.time = time
    }
}
