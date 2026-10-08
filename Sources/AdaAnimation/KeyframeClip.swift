//
//  KeyframeClip.swift
//  AdaAnimation
//

import AdaUtils

// MARK: - Track

/// Type-erased keyframe track for a single property of `Value`.
public struct AnyKeyframeTrack<Value>: @unchecked Sendable {
    /// String identifier used for JSON serialization (e.g. `"transform.position"`).
    public let identifier: String

    /// Keyframes in JSON-friendly form (raw float components + time + curve).
    public let serializedKeyframes: [SerializedKeyframe]

    /// Advances `value[keyPath]` to the interpolated result at `localTime`.
    let applyFn: (inout Value, TimeInterval) -> Void

    public init(
        identifier: String,
        serializedKeyframes: [SerializedKeyframe],
        applyFn: @escaping (inout Value, TimeInterval) -> Void
    ) {
        self.identifier = identifier
        self.serializedKeyframes = serializedKeyframes
        self.applyFn = applyFn
    }
}

// MARK: - Clip

/// A generic keyframe clip that drives properties of a user-defined `Value` struct over time.
///
/// ```swift
/// struct MyAnim: Sendable {
///     var transform = Transform()
/// }
///
/// let clip = KeyframeClip(name: "idle", initialValues: MyAnim(), duration: 2, repeatMode: .loop) {
///     KeyframeTrack(\.transform.position) {
///         LinearKeyframe(Vector3(0, 25, 0), duration: 1)
///         LinearKeyframe(Vector3(0,  0, 0), duration: 1)
///     }
/// }
/// ```
public struct KeyframeClip<Value: Sendable>: Sendable {
    public var name: String
    public var duration: TimeInterval
    public var repeatMode: KeyframeRepeatMode
    public var initialValues: Value
    public var tracks: [AnyKeyframeTrack<Value>]

    public init(
        name: String,
        initialValues: Value,
        duration: TimeInterval,
        repeatMode: KeyframeRepeatMode = .once,
        tracks: [AnyKeyframeTrack<Value>] = []
    ) {
        self.name = name
        self.initialValues = initialValues
        self.duration = max(0, duration)
        self.repeatMode = repeatMode
        self.tracks = tracks
    }

    /// Returns `initialValues` mutated by all tracks evaluated at `localTime`.
    public func evaluate(at localTime: TimeInterval) -> Value {
        var result = initialValues
        for track in tracks {
            track.applyFn(&result, localTime)
        }
        return result
    }
}
