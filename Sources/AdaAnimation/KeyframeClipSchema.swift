//
//  KeyframeClipSchema.swift
//  AdaAnimation
//

import AdaUtils
import Foundation
import Math

// MARK: - Schema entry (one registered keypath)

private struct SchemaEntry<Value>: @unchecked Sendable {
    let identifier: String
    /// Builds an `AnyKeyframeTrack<Value>` from serialized keyframe data.
    let makeTrack: ([SerializedKeyframe]) -> AnyKeyframeTrack<Value>?
}

// MARK: - Schema

/// A lookup table that maps string identifiers to `WritableKeyPath`s for JSON deserialization.
///
/// Use it to decode a ``KeyframeClip`` that was saved to JSON:
/// ```swift
/// var schema = KeyframeClipSchema<MyAnim>()
/// schema.register("transform.position", keyPath: \.transform.position, type: Vector3.self)
/// schema.registerQuat("transform.rotation", keyPath: \.transform.rotation)
/// let clip = try KeyframeClip(jsonData: data, schema: schema)
/// ```
public struct KeyframeClipSchema<Value: Sendable>: @unchecked Sendable {
    private var entries: [String: SchemaEntry<Value>] = [:]

    public init() {}

    // MARK: - Registration

    /// Register a `VectorArithmetic` keypath (Float, Double, Vector2, Vector3, Vector4 …).
    public mutating func register<T: VectorArithmetic & Sendable>(
        _ id: String,
        keyPath: WritableKeyPath<Value, T>,
        type _: T.Type = T.self
    ) {
        entries[id] = SchemaEntry(identifier: id) { keyframes in
            var tuples: [(time: AdaUtils.TimeInterval, value: T, curveToNext: KeyframeCurveKind)] = []
            for kf in keyframes {
                guard let value = convertFloats(kf.value, to: T.self) else {
                    continue
                }
                tuples.append((AdaUtils.TimeInterval(kf.time), value, kf.curveToNext))
            }
            let serialized = keyframes
            let path = keyPath
            return AnyKeyframeTrack<Value>(
                identifier: id,
                serializedKeyframes: serialized,
                applyFn: { value, localTime in
                    if let v = sampleVectorArithmetic(keyframes: tuples, localTime: localTime) {
                        value[keyPath: path] = v
                    }
                }
            )
        }
    }

    /// Register a `Quat` keypath (slerp interpolation).
    public mutating func registerQuat(
        _ id: String,
        keyPath: WritableKeyPath<Value, Quat>
    ) {
        entries[id] = SchemaEntry(identifier: id) { keyframes in
            let qkfs = keyframes.compactMap { kf -> QuaternionKeyframe? in
                guard kf.value.count == 4 else {
                    return nil
                }
                var q = Quat.identity
                q.x = kf.value[0]
                q.y = kf.value[1]
                q.z = kf.value[2]
                q.w = kf.value[3]
                return QuaternionKeyframe(time: TimeInterval(kf.time), value: q, curveToNext: kf.curveToNext)
            }
            let serialized = keyframes
            let path = keyPath
            return AnyKeyframeTrack<Value>(
                identifier: id,
                serializedKeyframes: serialized,
                applyFn: { value, localTime in
                    if let v = sampleQuaternionKeyframes(qkfs, localTime: localTime) {
                        value[keyPath: path] = v
                    }
                }
            )
        }
    }

    // MARK: - Internal

    func makeTrack(for id: String, keyframes: [SerializedKeyframe]) -> AnyKeyframeTrack<Value>? {
        entries[id]?.makeTrack(keyframes)
    }
}

// MARK: - Clip JSON codec (Value: Codable)

/// Errors thrown when decoding a keyframe clip from JSON.
public enum KeyframeClipDecodeError: Error, Sendable {
    case unsupportedVersion(Int)
    case unknownTrackIdentifier(String)
    case malformedJSON(String)
}

// MARK: - DTO

private struct KeyframeClipDTO<InitialValues: Codable>: Codable {
    var version: Int
    var name: String
    var duration: Double
    var repeatMode: KeyframeRepeatMode
    var initialValues: InitialValues?
    var tracks: [TrackDTO]
}

private struct TrackDTO: Codable {
    var id: String
    var keyframes: [SerializedKeyframeDTO]
}

private struct SerializedKeyframeDTO: Codable {
    var time: Double
    var value: [Float]
    var curve: KeyframeCurveKind
}

// MARK: - Encode

extension KeyframeClip where Value: Codable {
    /// Encode the clip as JSON (version 2). `initialValues` included because `Value: Codable`.
    public func encodeToJSONData(prettyPrinted: Bool = false) throws -> Data {
        let dto = KeyframeClipDTO<Value>(
            version: 2,
            name: name,
            duration: Double(duration),
            repeatMode: repeatMode,
            initialValues: initialValues,
            tracks: tracks.map { track in
                TrackDTO(
                    id: track.identifier,
                    keyframes: track.serializedKeyframes.map {
                        SerializedKeyframeDTO(time: $0.time, value: $0.value, curve: $0.curveToNext)
                    }
                )
            }
        )
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(dto)
    }
}

// MARK: - Decode

extension KeyframeClip where Value: Codable {
    /// Decode a clip from JSON (version 2) using a ``KeyframeClipSchema`` for track reconstruction.
    public init(jsonData: Data, schema: KeyframeClipSchema<Value>) throws {
        let decoder = JSONDecoder()
        let dto = try decoder.decode(KeyframeClipDTO<Value>.self, from: jsonData)
        guard dto.version == 2 else {
            throw KeyframeClipDecodeError.unsupportedVersion(dto.version)
        }
        var tracks: [AnyKeyframeTrack<Value>] = []
        for trackDTO in dto.tracks {
            let kfs = trackDTO.keyframes.map {
                SerializedKeyframe(time: $0.time, value: $0.value, curveToNext: $0.curveToNext)
            }
            guard let track = schema.makeTrack(for: trackDTO.id, keyframes: kfs) else {
                throw KeyframeClipDecodeError.unknownTrackIdentifier(trackDTO.id)
            }
            tracks.append(track)
        }
        let initial: Value
        if let v = dto.initialValues {
            initial = v
        } else {
            initial = try Self.makeDefaultInitialValues(from: jsonData)
        }
        self.init(
            name: dto.name,
            initialValues: initial,
            duration: TimeInterval(dto.duration),
            repeatMode: dto.repeatMode,
            tracks: tracks
        )
    }

    private static func makeDefaultInitialValues(from _: Data) throws -> Value {
        throw KeyframeClipDecodeError.malformedJSON("initialValues is required when decoding but was missing from JSON.")
    }
}

// MARK: - Float conversion helpers

private func convertFloats<T: VectorArithmetic>(_ floats: [Float], to _: T.Type) -> T? {
    if T.self == Vector3.self {
        guard floats.count >= 3 else {
            return nil
        }
        return Vector3(floats[0], floats[1], floats[2]) as? T
    }
    if T.self == Vector2.self {
        guard floats.count >= 2 else {
            return nil
        }
        return Vector2(floats[0], floats[1]) as? T
    }
    if T.self == Vector4.self {
        guard floats.count >= 4 else {
            return nil
        }
        return Vector4(floats[0], floats[1], floats[2], floats[3]) as? T
    }
    if T.self == Float.self {
        guard let f = floats.first else {
            return nil
        }
        return f as? T
    }
    if T.self == Double.self {
        guard let f = floats.first else {
            return nil
        }
        return Double(f) as? T
    }
    return nil
}

extension SerializedKeyframeDTO {
    var curveToNext: KeyframeCurveKind { curve }
}
