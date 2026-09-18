//
//  AnyAnimatorClip.swift
//  AdaAnimation
//

import AdaECS
import AdaUtils

/// Type-erased clip stored in ``KeyframeAnimator``.
///
/// Created automatically from ``KeyframeClip`` by the `@KeyframeAnimatorBuilder` via `buildExpression`.
public struct AnyAnimatorClip: @unchecked Sendable {
    public let name: String
    public let duration: TimeInterval
    public let repeatMode: KeyframeRepeatMode

    /// Runtime: compute interpolated value and apply it to the entity.
    public let applyAt: (TimeInterval, Entity.ID, World) -> Void

    /// Serializable tracks for JSON encoding.
    public let serializedTracks: [AnySerializedTrack]

    public init<Value: KeyframeAnimatable>(_ clip: KeyframeClip<Value>) {
        self.name = clip.name
        self.duration = clip.duration
        self.repeatMode = clip.repeatMode
        self.serializedTracks = clip.tracks.map {
            AnySerializedTrack(identifier: $0.identifier, keyframes: $0.serializedKeyframes)
        }

        // Capture by value so the clip is safe across tasks.
        let captured = clip
        self.applyAt = { localTime, entityId, world in
            let value = captured.evaluate(at: localTime)
            value.apply(to: entityId, in: world)
        }
    }
}

/// Serializable track data carried by ``AnyAnimatorClip`` for JSON round-trips.
public struct AnySerializedTrack: Sendable {
    public let identifier: String
    public let keyframes: [SerializedKeyframe]

    public init(identifier: String, keyframes: [SerializedKeyframe]) {
        self.identifier = identifier
        self.keyframes = keyframes
    }
}
