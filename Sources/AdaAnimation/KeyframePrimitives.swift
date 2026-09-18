//
//  KeyframePrimitives.swift
//  AdaAnimation
//

import AdaUtils
import Math

// MARK: - Repeat Mode

/// How playback behaves after the clip passes its duration.
public enum KeyframeRepeatMode: Sendable, Hashable, Codable {
    case once
    /// Loops from the beginning. Pass `reversed: true` to play backwards on each repeat.
    case loop(reversed: Bool = false)
    case pingPong
    case repeatCount(Int)

    enum CodingKeys: String, CodingKey {
        case kind
        case count
        case reversed
    }

    enum Kind: String, Codable {
        case once
        case loop
        case pingPong
        case repeatCount
    }

    public init(from decoder: any Decoder) throws {
        // Backward-compat: old payload may be a plain string.
        if let single = try? decoder.singleValueContainer(),
            let value = try? single.decode(String.self) {
            switch value {
            case "once": self = .once
            case "loop": self = .loop()
            case "pingPong": self = .pingPong
            default: self = .once
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .once: self = .once
        case .loop:
            let reversed = (try? container.decode(Bool.self, forKey: .reversed)) ?? false
            self = .loop(reversed: reversed)
        case .pingPong: self = .pingPong
        case .repeatCount:
            self = .repeatCount(max(0, try container.decode(Int.self, forKey: .count)))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .once:
            var s = encoder.singleValueContainer()
            try s.encode("once")
        case let .loop(reversed):
            if !reversed {
                var s = encoder.singleValueContainer()
                try s.encode("loop")
            } else {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(Kind.loop, forKey: .kind)
                try c.encode(true, forKey: .reversed)
            }
        case .pingPong:
            var s = encoder.singleValueContainer()
            try s.encode("pingPong")
        case let .repeatCount(count):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(Kind.repeatCount, forKey: .kind)
            try c.encode(max(0, count), forKey: .count)
        }
    }
}

// MARK: - Curve

/// Easing applied between two consecutive keyframes.
public enum KeyframeCurveKind: String, Codable, Sendable, Hashable {
    case linear
    case hold
    case cubicInOut
}

// MARK: - Low-level keyframe rows (used by internal samplers)

public struct Vector3Keyframe: Sendable, Hashable {
    public var time: TimeInterval
    public var value: Vector3
    public var curveToNext: KeyframeCurveKind

    public init(time: TimeInterval, value: Vector3, curveToNext: KeyframeCurveKind = .linear) {
        self.time = time
        self.value = value
        self.curveToNext = curveToNext
    }
}

public struct QuaternionKeyframe: Sendable, Hashable {
    public var time: TimeInterval
    public var value: Quat
    public var curveToNext: KeyframeCurveKind

    public init(time: TimeInterval, value: Quat, curveToNext: KeyframeCurveKind = .linear) {
        self.time = time
        self.value = value
        self.curveToNext = curveToNext
    }
}

public struct ScalarKeyframe: Sendable, Hashable {
    public var time: TimeInterval
    public var value: Double
    public var curveToNext: KeyframeCurveKind

    public init(time: TimeInterval, value: Double, curveToNext: KeyframeCurveKind = .linear) {
        self.time = time
        self.value = value
        self.curveToNext = curveToNext
    }
}

// MARK: - Serialized keyframe (JSON storage format)

/// A single keyframe stored as raw float components for JSON encoding.
public struct SerializedKeyframe: Codable, Sendable, Hashable {
    public var time: Double
    public var value: [Float]
    public var curveToNext: KeyframeCurveKind

    public init(time: Double, value: [Float], curveToNext: KeyframeCurveKind = .linear) {
        self.time = time
        self.value = value
        self.curveToNext = curveToNext
    }
}
