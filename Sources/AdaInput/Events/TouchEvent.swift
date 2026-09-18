//
//  TouchEvent.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

import AdaUtils
import Math

// TODO: (Vlad) Number of taps?
// TODO: (Vlad) finger index?
// TODO: (Vlad) Angles?
// TODO: (Vlad) radius of pressure?

/// Event describing the status of a finger touching the screen.
public struct TouchEvent: InputEvent {
    /// Describe the phase of a finger touch
    public enum Phase: Hashable, Sendable {
        case began
        case moved
        case ended
        case cancelled
    }

    /// The position of the touch in screen space pixel coordinates.
    public let location: Point

    /// Describe the phase of a finger touch
    public let phase: Phase

    public let id: RID = RID()

    /// Stable identity of a finger from began through ended/cancelled; distinct from the event ID.
    public let contactID: RID

    public let window: RID

    public let time: TimeInterval

    public init(window: RID, location: Point, phase: Phase, time: TimeInterval, contactID: RID? = nil) {
        self.location = location
        self.phase = phase
        self.contactID = contactID ?? window
        self.window = window
        self.time = time
    }
}
