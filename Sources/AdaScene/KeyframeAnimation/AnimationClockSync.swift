//
//  AnimationClockSync.swift
//  AdaScene
//

import AdaAnimation
import AdaECS

/// Keeps ``AnimationClock`` in sync with ``DeltaTime`` for UI and other consumers.
@System
@inline(__always)
public func SyncAnimationClock(
    _ deltaTime: Res<DeltaTime>,
    _ clock: ResMut<AnimationClock>
) {
    clock.wrappedValue.advance(from: deltaTime.wrappedValue)
}
