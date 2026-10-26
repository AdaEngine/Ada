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
    /// Relative movement, independent of a captured cursor's fixed position.
    /// Nil lets legacy/synthetic hosts derive motion from successive positions.
    public let motionDelta: Vector2?
    /// Whether the scroll delta came from a high-resolution source such as a trackpad.
    public var hasPreciseScrollingDeltas = false
    public let modifierKeys: KeyModifier
    public let phase: Phase

    public let id: RID = RID()

    public let window: RID

    public let time: TimeInterval

    public init(
        window: RID,
        button: MouseButton,
        scrollDelta: Point = .zero,
        motionDelta: Vector2? = nil,
        mousePosition: Point,
        phase: Phase,
        modifierKeys: KeyModifier,
        time: TimeInterval
    ) {
        self.scrollDelta = scrollDelta
        self.motionDelta = motionDelta
        self.button = button
        self.mousePosition = mousePosition
        self.modifierKeys = modifierKeys
        self.phase = phase
        self.window = window
        self.time = time
    }
}
