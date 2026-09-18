//
//  AnimationClock.swift
//  AdaAnimation
//

import AdaECS
import AdaUtils

/// Shared animation time for UI and ECS. Updated each frame from ``DeltaTime`` (see ``syncAnimationClockFromDeltaTime(_:)``).
///
/// Insert this resource in your world and run a small system early in ``SchedulerName/update`` so tweens and keyframes share the same clock if you wire consumers to it.
public struct AnimationClock: Resource, Sendable {
    /// Monotonic elapsed time in seconds (scaled, after pause handling).
    public var elapsed: TimeInterval

    /// Last frame delta in seconds (scaled).
    public var delta: TimeInterval

    /// Multiplier applied to incoming delta time when advancing.
    public var timeScale: Double

    /// When `true`, ``advance(delta:)`` does not change ``elapsed``.
    public var paused: Bool

    public init(
        elapsed: TimeInterval = 0,
        delta: TimeInterval = 0,
        timeScale: Double = 1,
        paused: Bool = false
    ) {
        self.elapsed = elapsed
        self.delta = delta
        self.timeScale = timeScale
        self.paused = paused
    }

    /// Advance the clock using an unscaled delta (typically ``DeltaTime/deltaTime``).
    public mutating func advance(delta rawDelta: TimeInterval) {
        let scaled = TimeInterval(Double(rawDelta) * timeScale)
        self.delta = scaled
        if !paused {
            self.elapsed += scaled
        }
    }

    /// Advance using the frame delta from ``DeltaTime`` (inserted by the main scheduler each tick).
    public mutating func advance(from deltaTime: DeltaTime) {
        advance(delta: deltaTime.deltaTime)
    }
}
