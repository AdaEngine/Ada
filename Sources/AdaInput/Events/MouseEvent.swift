//
//  MouseEvent.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

import AdaUtils
import Math

/// An object that contains information about mouse event.
public struct MouseEvent: InputEvent {
    public enum Phase: UInt8, Hashable, Sendable {
        case began
        case changed
        case ended
        case cancelled
    }

    public let button: MouseButton
    public let mousePosition: Point
    public let scrollDelta: Point
    public let modifierKeys: KeyModifier
    public let phase: Phase

    public let id: RID = RID()

    public let window: RID

    public let time: TimeInterval

    public init(
        window: RID,
        button: MouseButton,
        scrollDelta: Point = .zero,
        mousePosition: Point,
        phase: Phase,
        modifierKeys: KeyModifier,
        time: TimeInterval
    ) {
        self.scrollDelta = scrollDelta
        self.button = button
        self.mousePosition = mousePosition
        self.modifierKeys = modifierKeys
        self.phase = phase
        self.window = window
        self.time = time
    }
}
