//
//  KeyboardEvent.swift
//  AdaEngine
//
//  Created by OpenAI Codex on 30.04.2026.
//

import AdaUtils
import Math

/// An event emitted when the platform software keyboard changes visibility or frame.
public struct KeyboardEvent: InputEvent {
    public enum Phase: UInt8, Hashable, Sendable {
        case willShow
        case didShow
        case willHide
        case didHide
        case willChangeFrame
        case didChangeFrame
    }

    public var id: RID = RID()

    /// The window that received the keyboard event.
    public let window: RID

    /// The lifecycle phase reported by the platform.
    public let phase: Phase

    /// The keyboard frame before the transition, in window coordinates.
    public let beginFrame: Rect

    /// The keyboard frame after the transition, in window coordinates.
    public let endFrame: Rect

    /// The part of ``endFrame`` that overlaps the window content.
    public let occludedFrame: Rect

    /// The vertical window area currently covered by the keyboard.
    public let occludedHeight: Float

    /// The platform animation duration in seconds.
    public let animationDuration: TimeInterval

    /// The platform animation curve raw value when available.
    public let animationCurve: Int

    /// The timestamp of the event.
    public var time: TimeInterval

    public var isVisible: Bool {
        switch phase {
        case .willHide,
            .didHide:
            return false
        case .willShow,
            .didShow,
            .willChangeFrame,
            .didChangeFrame:
            return occludedHeight > 0
        }
    }

    public init(
        window: RID,
        phase: Phase,
        beginFrame: Rect,
        endFrame: Rect,
        occludedFrame: Rect,
        occludedHeight: Float,
        animationDuration: TimeInterval,
        animationCurve: Int,
        time: TimeInterval
    ) {
        self.window = window
        self.phase = phase
        self.beginFrame = beginFrame
        self.endFrame = endFrame
        self.occludedFrame = occludedFrame
        self.occludedHeight = occludedHeight
        self.animationDuration = animationDuration
        self.animationCurve = animationCurve
        self.time = time
    }
}
