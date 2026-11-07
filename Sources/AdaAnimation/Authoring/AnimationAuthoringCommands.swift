import Foundation
import Math

/// A detached edit shared by native authoring, script Tools and agent transports.
/// `replaceExisting` permits replacing the same key ID; a different key at that time remains a conflict.
public struct AnimationEdit: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case createClip = "clip.create", duplicateClip = "clip.duplicate", removeClip = "clip.remove", configureClip = "clip.configure"
        case createTrack = "track.create", removeTrack = "track.remove", configureTrack = "track.configure"
        case putKey = "key.put", removeKey = "key.remove"
    }

    public var id: String
    public var kind: Kind
    public var clipID: String?
    public var trackID: String?
    public var keyID: String?
    public var newID: String?
    public var name: String?
    public var duration: Double?
    public var repeats: Bool?
    public var interpolation: AnimationLibraryTrack.Interpolation?
    public var clip: AnimationLibraryClip?
    public var track: AnimationLibraryTrack?
    public var key: AnimationLibraryKey?
    public var replaceExisting: Bool

    public init(id: String = UUID().uuidString, kind: Kind, clipID: String? = nil, trackID: String? = nil, keyID: String? = nil,
                newID: String? = nil, name: String? = nil, duration: Double? = nil, repeats: Bool? = nil,
                interpolation: AnimationLibraryTrack.Interpolation? = nil, clip: AnimationLibraryClip? = nil,
                track: AnimationLibraryTrack? = nil, key: AnimationLibraryKey? = nil, replaceExisting: Bool = false) {
        self.id = id
        self.kind = kind
        self.clipID = clipID
        self.trackID = trackID
        self.keyID = keyID
        self.newID = newID
        self.name = name
        self.duration = duration
        self.repeats = repeats
        self.interpolation = interpolation
        self.clip = clip
        self.track = track
        self.key = key
        self.replaceExisting = replaceExisting
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, clipID, trackID, keyID, newID, name, duration, repeats, interpolation, clip, track, key, replaceExisting
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            kind: try values.decode(Kind.self, forKey: .kind),
            clipID: try values.decodeIfPresent(String.self, forKey: .clipID),
            trackID: try values.decodeIfPresent(String.self, forKey: .trackID),
            keyID: try values.decodeIfPresent(String.self, forKey: .keyID),
            newID: try values.decodeIfPresent(String.self, forKey: .newID),
            name: try values.decodeIfPresent(String.self, forKey: .name),
            duration: try values.decodeIfPresent(Double.self, forKey: .duration),
            repeats: try values.decodeIfPresent(Bool.self, forKey: .repeats),
            interpolation: try values.decodeIfPresent(AnimationLibraryTrack.Interpolation.self, forKey: .interpolation),
            clip: try values.decodeIfPresent(AnimationLibraryClip.self, forKey: .clip),
            track: try values.decodeIfPresent(AnimationLibraryTrack.self, forKey: .track),
            key: try values.decodeIfPresent(AnimationLibraryKey.self, forKey: .key),
            replaceExisting: try values.decodeIfPresent(Bool.self, forKey: .replaceExisting) ?? false
        )
    }
}

/// The failed operation and a stable authoring diagnostic. No operations in its batch are committed.
public struct AnimationEditError: Error, Equatable, LocalizedError, Sendable {
    public let operationID: String
    public let diagnostic: AnimationAuthoringError
    public var errorDescription: String? { "\(operationID): \(diagnostic.message)" }

    public init(operationID: String, diagnostic: AnimationAuthoringError) {
        self.operationID = operationID
        self.diagnostic = diagnostic
    }
}

extension AnimationLibrary {
    /// Applies a bounded batch to a detached draft. Each operation must leave a valid library.
    /// Failed batches preserve the original value; put-key never overwrites an occupied time implicitly.
    public mutating func apply(_ operations: [AnimationEdit]) throws(AnimationEditError) {
        guard operations.count <= 256 else {
            throw .init(operationID: "batch", diagnostic: .init(.limitExceeded, itemID: id, message: "A batch supports at most 256 operations."))
        }
        var draft = self
        var identities: Set<String> = []
        for operation in operations {
            do throws(AnimationAuthoringError) {
                guard !operation.id.isEmpty, operation.id.utf8.count <= 256, identities.insert(operation.id).inserted else {
                    throw AnimationAuthoringError(.invalidIdentity, itemID: operation.id, message: "Operation IDs must be nonempty, unique and bounded.")
                }
                try draft.perform(operation)
                draft.promoteNativeCurveFormat()
                try draft.validate()
            } catch {
                throw .init(operationID: operation.id, diagnostic: error)
            }
        }
        self = draft
    }

    private mutating func perform(_ operation: AnimationEdit) throws(AnimationAuthoringError) {
        if operation.kind == .createClip {
            guard let clip = operation.clip else { throw missing("clip", operation.id) }
            clips.append(clip)
            return
        }
        guard let clipIndex = clips.firstIndex(where: { $0.id == operation.clipID }) else {
            throw .init(.missingClip, itemID: operation.clipID ?? "", message: "Clip does not exist.")
        }
        switch operation.kind {
        case .createClip: break
        case .duplicateClip:
            guard let newID = operation.newID, let name = operation.name else { throw missing("newID and name", operation.id) }
            var clip = clips[clipIndex]
            clip.id = newID
            clip.name = name
            clips.append(clip)
        case .removeClip: clips.remove(at: clipIndex)
        case .configureClip:
            if let name = operation.name { clips[clipIndex].name = name }
            if let duration = operation.duration { clips[clipIndex].duration = duration }
            if let repeats = operation.repeats { clips[clipIndex].repeats = repeats }
        case .createTrack:
            guard let track = operation.track else { throw missing("track", operation.id) }
            clips[clipIndex].tracks.append(track)
        default: try performTrackEdit(operation, clipIndex: clipIndex)
        }
    }

    private mutating func performTrackEdit(_ operation: AnimationEdit, clipIndex: Int) throws(AnimationAuthoringError) {
        guard let trackIndex = clips[clipIndex].tracks.firstIndex(where: { $0.id == operation.trackID }) else {
            throw .init(.missingTrack, itemID: operation.trackID ?? "", message: "Track does not exist.")
        }
        switch operation.kind {
        case .removeTrack: clips[clipIndex].tracks.remove(at: trackIndex)
        case .configureTrack:
            guard let interpolation = operation.interpolation else { throw missing("interpolation", operation.id) }
            clips[clipIndex].tracks[trackIndex].interpolation = interpolation
        case .putKey:
            guard let key = operation.key, key.time.isFinite, key.time >= 0 else { throw missing("finite key", operation.id) }
            var keys = clips[clipIndex].tracks[trackIndex].keys
            if let existing = keys.firstIndex(where: { $0.id == key.id }) {
                guard operation.replaceExisting else {
                    throw .init(.conflict, itemID: key.id, message: "Replacing an existing key ID requires replaceExisting.")
                }
                keys.remove(at: existing)
            }
            guard !keys.contains(where: { $0.time == key.time }) else {
                throw .init(.conflict, itemID: key.id, message: "Another key occupies this time. Remove it explicitly first.")
            }
            keys.append(key)
            clips[clipIndex].tracks[trackIndex].keys = keys.sorted { $0.time < $1.time }
        case .removeKey:
            guard let keyIndex = clips[clipIndex].tracks[trackIndex].keys.firstIndex(where: { $0.id == operation.keyID }) else {
                throw .init(.missingKey, itemID: operation.keyID ?? "", message: "Key does not exist.")
            }
            clips[clipIndex].tracks[trackIndex].keys.remove(at: keyIndex)
        default: throw missing("track operation", operation.id)
        }
    }

    private func missing(_ field: String, _ id: String) -> AnimationAuthoringError {
        .init(.invalidTrack, itemID: id, message: "Operation requires \(field).")
    }

    /// Builds a new clip from rest or a compatible captured player, without sharing playback buffers.
    public func poseClip(id clipID: String = UUID().uuidString, name: String, duration: Double,
                         from player: SkeletalAnimationPlayer? = nil) throws -> AnimationLibraryClip {
        let rig = try binding.makeRig()
        if let player, !binding.isCompatible(with: player.rig) {
            throw AnimationAuthoringError(.incompatibleRig, itemID: id, message: "Captured pose uses a different rig.")
        }
        var tracks: [AnimationLibraryTrack] = []
        for (index, node) in binding.nodes.enumerated() {
            if let rest = rig.nodes[index].restPose {
                let pose = player?.poses[index] ?? rest
                let values: [(AnimationLibraryTrack.Channel, [Float])] = [
                    (.translation, [pose.translation.x, pose.translation.y, pose.translation.z]),
                    (.rotation, [pose.rotation.x, pose.rotation.y, pose.rotation.z, pose.rotation.w]),
                    (.scale, [pose.scale.x, pose.scale.y, pose.scale.z])
                ]
                for (channel, value) in values {
                    tracks.append(.init(nodeID: node.id, channel: channel, keys: [.init(time: 0, value: value)]))
                }
            }
            if let weights = player?.morphWeights[index] ?? node.morphRestWeights, !weights.isEmpty {
                tracks.append(.init(nodeID: node.id, channel: .weights, keys: [.init(time: 0, value: weights)]))
            }
        }
        let clip = AnimationLibraryClip(id: clipID, name: name, duration: duration, tracks: tracks)
        var draft = self
        draft.clips.append(clip)
        try draft.validate()
        return clip
    }
}
