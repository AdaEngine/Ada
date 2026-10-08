//
//  KeyframeDSL.swift
//  AdaAnimation
//

import AdaUtils
import Math

// MARK: - LinearKeyframe

/// A keyframe segment where the property linearly interpolates over `duration` seconds
/// from the previous value to this `value`.
public struct LinearKeyframe<Value>: Sendable where Value: Sendable {
    public let value: Value
    public let duration: TimeInterval
    public let curve: KeyframeCurveKind

    public init(_ value: Value, duration: TimeInterval, curve: KeyframeCurveKind = .linear) {
        self.value = value
        self.duration = duration
        self.curve = curve
    }
}

/// Spelling alias — matches the typo in the original snippet.
public typealias LinearKeyrame<Value> = LinearKeyframe<Value> where Value: Sendable

// MARK: - CubicKeyframe

/// A keyframe segment that eases in/out using a cubic curve.
public struct CubicKeyframe<Value>: Sendable where Value: Sendable {
    public let value: Value
    public let duration: TimeInterval

    public init(_ value: Value, duration: TimeInterval) {
        self.value = value
        self.duration = duration
    }
}

// MARK: - Result Builders

@resultBuilder
public enum KeyframeLinearVABuilder<T: VectorArithmetic & Sendable> {
    public static func buildBlock(_ components: [LinearKeyframe<T>]...) -> [LinearKeyframe<T>] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ frame: LinearKeyframe<T>) -> [LinearKeyframe<T>] { [frame] }
    public static func buildExpression(_ frame: CubicKeyframe<T>) -> [LinearKeyframe<T>] {
        [LinearKeyframe(frame.value, duration: frame.duration, curve: .cubicInOut)]
    }
    /// Allows programmatic tracks: `KeyframeTrack(path, identifier: id) { prebuiltFrames }`.
    public static func buildExpression(_ frames: [LinearKeyframe<T>]) -> [LinearKeyframe<T>] { frames }
}

@resultBuilder
public enum KeyframeLinearQuatBuilder {
    public static func buildBlock(_ components: [LinearKeyframe<Quat>]...) -> [LinearKeyframe<Quat>] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ frame: LinearKeyframe<Quat>) -> [LinearKeyframe<Quat>] { [frame] }
    public static func buildExpression(_ frame: CubicKeyframe<Quat>) -> [LinearKeyframe<Quat>] {
        [LinearKeyframe(frame.value, duration: frame.duration, curve: .cubicInOut)]
    }
    public static func buildExpression(_ frames: [LinearKeyframe<Quat>]) -> [LinearKeyframe<Quat>] { frames }
}

@resultBuilder
public enum KeyframeTrackBuilder<Value: Sendable> {
    public static func buildBlock(_ tracks: AnyKeyframeTrack<Value>...) -> [AnyKeyframeTrack<Value>] {
        tracks
    }
    // Allow expression results to flow through.
    public static func buildExpression(_ track: AnyKeyframeTrack<Value>) -> AnyKeyframeTrack<Value> { track }
}

@resultBuilder
public enum KeyframeAnimatorBuilder {
    /// Convert a concrete `KeyframeClip<Value>` to `AnyAnimatorClip` at the build site.
    public static func buildExpression<Value: KeyframeAnimatable>(_ clip: KeyframeClip<Value>) -> AnyAnimatorClip {
        AnyAnimatorClip(clip)
    }

    public static func buildBlock(_ clips: AnyAnimatorClip...) -> [AnyAnimatorClip] {
        clips
    }
}

@resultBuilder
public enum KeyframeClipArrayBuilder {
    public static func buildExpression<Value: KeyframeAnimatable>(_ clip: KeyframeClip<Value>) -> AnyAnimatorClip {
        AnyAnimatorClip(clip)
    }
    public static func buildBlock(_ clips: AnyAnimatorClip...) -> [AnyAnimatorClip] { clips }
}

// MARK: - KeyframeTrack DSL functions

// These produce `AnyKeyframeTrack<Value>` from a WritableKeyPath + array of LinearKeyframe segments.
// Segments are accumulated in time order: each frame starts right after the previous ends.

private func keyframeTrackFromLinearFrames<Value: Sendable, T: VectorArithmetic & Sendable>(
    _ keyPath: WritableKeyPath<Value, T>,
    identifier: String?,
    frames: [LinearKeyframe<T>]
) -> AnyKeyframeTrack<Value> {
    let id = identifier ?? "\(keyPath)"
    var time: TimeInterval = 0
    let keyframes: [(time: TimeInterval, value: T, curveToNext: KeyframeCurveKind)] = frames.map { f in
        defer { time += f.duration }
        return (time, f.value, f.curve)
    }
    let serialized = keyframes.map { kf -> SerializedKeyframe in
        SerializedKeyframe(
            time: Double(kf.time),
            value: floatComponents(of: kf.value),
            curveToNext: kf.curveToNext
        )
    }
    let path = keyPath
    return AnyKeyframeTrack<Value>(
        identifier: id,
        serializedKeyframes: serialized,
        applyFn: { value, localTime in
            if let result = sampleVectorArithmetic(keyframes: keyframes, localTime: localTime) {
                value[keyPath: path] = result
            }
        }
    )
}

/// Track for any `VectorArithmetic` property (Float, Double, Vector2, Vector3, Vector4 …).
public func KeyframeTrack<Value: Sendable, T: VectorArithmetic & Sendable>(
    _ keyPath: WritableKeyPath<Value, T>,
    identifier: String? = nil,
    @KeyframeLinearVABuilder<T> _ build: () -> [LinearKeyframe<T>]
) -> AnyKeyframeTrack<Value> {
    keyframeTrackFromLinearFrames(keyPath, identifier: identifier, frames: build())
}

/// Same as ``KeyframeTrack(_:identifier:_:)``, but accepts a runtime-built segment array (e.g. editor tooling).
public func KeyframeTrack<Value: Sendable, T: VectorArithmetic & Sendable>(
    _ keyPath: WritableKeyPath<Value, T>,
    identifier: String? = nil,
    linearFrames frames: [LinearKeyframe<T>]
) -> AnyKeyframeTrack<Value> {
    keyframeTrackFromLinearFrames(keyPath, identifier: identifier, frames: frames)
}

/// Track for `Quat` (uses slerp interpolation, not linear).
public func KeyframeTrack<Value: Sendable>(
    _ keyPath: WritableKeyPath<Value, Quat>,
    identifier: String? = nil,
    @KeyframeLinearQuatBuilder _ build: () -> [LinearKeyframe<Quat>]
) -> AnyKeyframeTrack<Value> {
    let frames = build()
    let id = identifier ?? "\(keyPath)"
    var time: TimeInterval = 0
    let keyframes: [QuaternionKeyframe] = frames.map { f in
        defer { time += f.duration }
        return QuaternionKeyframe(time: time, value: f.value, curveToNext: f.curve)
    }
    let serialized = keyframes.map { kf in
        SerializedKeyframe(
            time: Double(kf.time),
            value: [kf.value.x, kf.value.y, kf.value.z, kf.value.w],
            curveToNext: kf.curveToNext
        )
    }
    let path = keyPath
    return AnyKeyframeTrack<Value>(
        identifier: id,
        serializedKeyframes: serialized,
        applyFn: { value, localTime in
            if let result = sampleQuaternionKeyframes(keyframes, localTime: localTime) {
                value[keyPath: path] = result
            }
        }
    )
}

// MARK: - KeyframeClip DSL init

extension KeyframeClip {
    /// Create a keyframe clip using result-builder syntax.
    ///
    /// ```swift
    /// KeyframeClip(name: "idle", initialValues: MyAnim(), duration: 2, repeatMode: .loop) {
    ///     KeyframeTrack(\.transform.position) {
    ///         LinearKeyframe(Vector3(0, 25, 0), duration: 1)
    ///         LinearKeyframe(Vector3(0,  0, 0), duration: 1)
    ///     }
    /// }
    /// ```
    public init(
        name: String,
        initialValues: Value,
        duration: TimeInterval,
        repeatMode: KeyframeRepeatMode = .once,
        @KeyframeTrackBuilder<Value> _ build: () -> [AnyKeyframeTrack<Value>]
    ) {
        self.init(
            name: name,
            initialValues: initialValues,
            duration: duration,
            repeatMode: repeatMode,
            tracks: build()
        )
    }
}

// MARK: - Helpers

/// Extracts float components from a `VectorArithmetic` value for JSON storage.
/// Specialised for known types; falls back to a single zero component for unknown types.
private func floatComponents<T: VectorArithmetic>(of value: T) -> [Float] {
    if let v = value as? Vector3 {
        return [v.x, v.y, v.z]
    }
    if let v = value as? Vector2 {
        return [v.x, v.y]
    }
    if let v = value as? Vector4 {
        return [v.x, v.y, v.z, v.w]
    }
    if let v = value as? Float {
        return [v]
    }
    if let v = value as? Double {
        return [Float(v)]
    }
    return [Float(value.magnitudeSquared)]
}
