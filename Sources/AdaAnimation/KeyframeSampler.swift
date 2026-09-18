//
//  KeyframeSampler.swift
//  AdaAnimation
//

import AdaUtils
import Math

// MARK: - Playback state

public struct KeyframePlaybackState: Sendable, Hashable {
    public let localTime: TimeInterval
    public let isFinished: Bool

    public init(localTime: TimeInterval, isFinished: Bool) {
        self.localTime = localTime
        self.isFinished = isFinished
    }
}

// MARK: - Normalised local time

/// Maps a playhead to a time in `[0, duration]` according to repeat mode.
public func keyframeNormalizedLocalTime(
    playhead: TimeInterval,
    duration: TimeInterval,
    mode: KeyframeRepeatMode
) -> TimeInterval {
    guard duration > 0 else {
        return 0
    }
    switch mode {
    case .once:
        return min(max(playhead, 0), duration)
    case let .loop(reversed):
        let t = playhead.truncatingRemainder(dividingBy: duration)
        let forward = t < 0 ? t + duration : t
        return reversed ? duration - forward : forward
    case .pingPong:
        let span = duration * 2
        guard span > 0 else {
            return 0
        }
        var t = playhead.truncatingRemainder(dividingBy: span)
        if t < 0 {
            t += span
        }
        if t > duration {
            return span - t
        }
        return t
    case .repeatCount:
        let t = playhead.truncatingRemainder(dividingBy: duration)
        return t < 0 ? t + duration : t
    }
}

/// Calculates normalised local time and whether playback completed for a given repeat mode.
public func keyframePlaybackState(
    playhead: TimeInterval,
    duration: TimeInterval,
    mode: KeyframeRepeatMode
) -> KeyframePlaybackState {
    guard duration > 0 else {
        return KeyframePlaybackState(localTime: 0, isFinished: true)
    }
    switch mode {
    case .once:
        let clamped = min(max(playhead, 0), duration)
        return KeyframePlaybackState(localTime: clamped, isFinished: playhead >= duration)
    case .loop,
        .pingPong:
        return KeyframePlaybackState(
            localTime: keyframeNormalizedLocalTime(playhead: playhead, duration: duration, mode: mode),
            isFinished: false
        )
    case let .repeatCount(count):
        let safe = max(0, count)
        if safe == 0 {
            return KeyframePlaybackState(localTime: 0, isFinished: true)
        }
        let maxPlayhead = TimeInterval(safe) * duration
        if playhead >= maxPlayhead {
            return KeyframePlaybackState(localTime: duration, isFinished: true)
        }
        let local = keyframeNormalizedLocalTime(playhead: playhead, duration: duration, mode: .loop())
        return KeyframePlaybackState(localTime: local, isFinished: false)
    }
}

// MARK: - Generic VectorArithmetic sampler

/// Interpolates between keyframes for any `VectorArithmetic` type (Float, Double, Vector2, Vector3, …).
public func sampleVectorArithmetic<T: VectorArithmetic>(
    keyframes: [(time: TimeInterval, value: T, curveToNext: KeyframeCurveKind)],
    localTime: TimeInterval
) -> T? {
    guard !keyframes.isEmpty else {
        return nil
    }
    let sorted = keyframes.sorted { $0.time < $1.time }
    if sorted.count == 1 {
        return sorted[0].value
    }
    if localTime <= sorted[0].time {
        return sorted[0].value
    }
    if localTime >= sorted[sorted.count - 1].time {
        return sorted[sorted.count - 1].value
    }
    guard let ri = sorted.firstIndex(where: { $0.time > localTime }), ri > 0 else {
        return sorted.last?.value
    }
    let left = sorted[ri - 1]
    let right = sorted[ri]
    let span = right.time - left.time
    guard span > 0 else {
        return left.value
    }
    var u = Double((localTime - left.time) / span)
    u = clamp01(u)
    u = applyCurveEasing(left.curveToNext, u: u)
    return left.value.interpolated(towards: right.value, amount: u)
}

// MARK: - Specialised Vector3 sampler (legacy / tests still use this)

public func sampleVector3Keyframes(_ keyframes: [Vector3Keyframe], localTime: TimeInterval) -> Vector3? {
    let tuples = keyframes.map { (time: $0.time, value: $0.value, curveToNext: $0.curveToNext) }
    return sampleVectorArithmetic(keyframes: tuples, localTime: localTime)
}

extension Vector3 {
    private func interpolated(towards other: Vector3, amount: Double) -> Vector3 {
        let a = Float(amount)
        return Vector3(x: x + (other.x - x) * a, y: y + (other.y - y) * a, z: z + (other.z - z) * a)
    }
}

// MARK: - Quaternion sampler (slerp)

public func sampleQuaternionKeyframes(_ keyframes: [QuaternionKeyframe], localTime: TimeInterval) -> Quat? {
    guard !keyframes.isEmpty else {
        return nil
    }
    let sorted = keyframes.sorted { $0.time < $1.time }
    if sorted.count == 1 {
        return sorted[0].value
    }
    if localTime <= sorted[0].time {
        return sorted[0].value
    }
    if localTime >= sorted[sorted.count - 1].time {
        return sorted[sorted.count - 1].value
    }
    guard let ri = sorted.firstIndex(where: { $0.time > localTime }), ri > 0 else {
        return sorted.last?.value
    }
    let left = sorted[ri - 1]
    let right = sorted[ri]
    let span = right.time - left.time
    guard span > 0 else {
        return left.value
    }
    var u = Double((localTime - left.time) / span)
    u = clamp01(u)
    u = applyCurveEasing(left.curveToNext, u: u)
    return slerpQuat(left.value, right.value, t: Float(u))
}

// MARK: - Scalar sampler

public func sampleScalarKeyframes(_ keyframes: [ScalarKeyframe], localTime: TimeInterval) -> Double? {
    let tuples = keyframes.map { (time: $0.time, value: $0.value, curveToNext: $0.curveToNext) }
    return sampleVectorArithmetic(keyframes: tuples, localTime: localTime)
}

// MARK: - Helpers

func clamp01(_ x: Double) -> Double {
    min(1, max(0, x))
}

func applyCurveEasing(_ curve: KeyframeCurveKind, u: Double) -> Double {
    switch curve {
    case .linear: return u
    case .hold: return 0
    case .cubicInOut:
        let t = clamp01(u)
        return t * t * (3 - 2 * t)
    }
}

func slerpQuat(_ a: Quat, _ b: Quat, t: Float) -> Quat {
    var cosHalfTheta = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    var b2 = b
    if cosHalfTheta < 0 {
        b2.x = -b.x
        b2.y = -b.y
        b2.z = -b.z
        b2.w = -b.w
        cosHalfTheta = -cosHalfTheta
    }
    if cosHalfTheta >= 1 - Float.ulpOfOne {
        var q = Quat()
        q.x = a.x + (b2.x - a.x) * t
        q.y = a.y + (b2.y - a.y) * t
        q.z = a.z + (b2.z - a.z) * t
        q.w = a.w + (b2.w - a.w) * t
        return q.normalized
    }
    let halfTheta = acos(min(1, max(-1, cosHalfTheta)))
    let sinHalfTheta = sqrt(1 - cosHalfTheta * cosHalfTheta)
    let ra = sin((1 - t) * halfTheta) / sinHalfTheta
    let rb = sin(t * halfTheta) / sinHalfTheta
    var out = Quat()
    out.x = a.x * ra + b2.x * rb
    out.y = a.y * ra + b2.y * rb
    out.z = a.z * ra + b2.z * rb
    out.w = a.w * ra + b2.w * rb
    return out.normalized
}
