import Foundation
import Math

extension AnimationLibrary {
    /// Checks portable data before saving, committing an edit, or compiling playback tracks.
    public func validate() throws(AnimationAuthoringError) {
        guard version == 1 || version == 2 else { throw .init(.unsupportedVersion, itemID: id, message: "Unsupported animation library version: \(version).") }
        guard version != 1 || !requiresNativeCurveFormat else {
            throw .init(.unsupportedVersion, itemID: id, message: "Native temporal curves require animation library version 2.")
        }
        try validateIdentities([id])
        try validateIdentities(binding.nodes.map(\.id))
        try validateIdentities(clips.map(\.id))
        guard binding.nodes.count <= 16_384, clips.count <= 256 else {
            throw .init(.limitExceeded, itemID: id, message: "A library supports at most 16384 rig nodes and 256 clips.")
        }
        try validateText(binding.sourceAsset, maximum: 4_096, itemID: id)
        let indices = Dictionary(uniqueKeysWithValues: binding.nodes.enumerated().map { ($0.element.id, $0.offset) })
        var rigNodes: [SkeletalRig.Node] = []
        for node in binding.nodes {
            try validateText(node.name ?? "", maximum: 1_024, itemID: node.id)
            guard (node.morphRestWeights?.count ?? 0) <= 1_024 else {
                throw .init(.limitExceeded, itemID: node.id, message: "A node supports at most 1024 morph targets.")
            }
            if let parent = node.parentID, indices[parent] == nil {
                throw .init(.missingTarget, itemID: node.id, message: "The parent binding does not exist.")
            }
            let matrix = node.restMatrix
            guard [matrix.x, matrix.y, matrix.z, matrix.w].allSatisfy({ [$0.x, $0.y, $0.z, $0.w].allSatisfy(\.isFinite) }),
                node.morphRestWeights?.allSatisfy(\.isFinite) != false else {
                throw .init(.invalidHierarchy, itemID: node.id, message: "Rest transforms and morph weights must be finite.")
            }
            let pose: SkeletalJointPose?
            switch (node.restTranslation, node.restRotation, node.restScale) {
            case let (translation?, rotation?, scale?):
                guard [translation.x, translation.y, translation.z, rotation.x, rotation.y, rotation.z, rotation.w,
                       scale.x, scale.y, scale.z].allSatisfy(\.isFinite), abs(rotation.dot(rotation) - 1) < 0.001 else {
                    throw .init(.invalidHierarchy, itemID: node.id, message: "Rest TRS needs finite values and a normalized quaternion.")
                }
                pose = .init(translation: translation, rotation: Quat(x: rotation.x, y: rotation.y, z: rotation.z, w: rotation.w), scale: scale)
            case (nil, nil, nil): pose = nil
            default: throw .init(.invalidHierarchy, itemID: node.id, message: "Rest TRS must contain translation, rotation and scale together.")
            }
            if let pose {
                let derived = pose.matrix
                for column in 0..<4 {
                    for row in 0..<4 {
                        let expected = matrix[column, row]
                        let difference = abs(derived[column, row] - expected)
                        guard difference.isFinite, difference <= 0.00001 * max(1, abs(expected)) else {
                            throw .init(.invalidHierarchy, itemID: node.id, message: "Rest TRS and the stored rest matrix must agree.")
                        }
                    }
                }
            }
            rigNodes.append(.init(parentIndex: node.parentID.flatMap { indices[$0] }, restPose: pose, restMatrix: matrix,
                                  name: node.name, morphRestWeights: node.morphRestWeights))
        }
        do { _ = try SkeletalRig(nodes: rigNodes) } catch {
            throw .init(.invalidHierarchy, itemID: id, message: "The rig binding contains a cycle.")
        }
        var keyCount = 0
        var curveComponents = 0
        for clip in clips {
            try validateText(clip.name, maximum: 1_024, itemID: clip.id)
            try validateText(clip.sourceClip ?? "", maximum: 1_024, itemID: clip.id)
            try validateText(clip.sourceFingerprint ?? "", maximum: 256, itemID: clip.id)
            guard clip.duration.isFinite, clip.duration >= 0 else {
                throw .init(.invalidDuration, itemID: clip.id, message: "Clip duration must be finite and nonnegative.")
            }
            guard !clip.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, clip.tracks.count <= 4_096 else {
                throw .init(.invalidTrack, itemID: clip.id, message: "A clip needs a name and at most 4096 tracks.")
            }
            try validateIdentities(clip.tracks.map(\.id))
            var targets: Set<String> = []
            for track in clip.tracks {
                guard let index = indices[track.nodeID] else {
                    throw .init(.missingTarget, itemID: track.id, message: "Track binding '\(track.nodeID)' does not exist.")
                }
                // Node IDs are length-delimited so channel-like suffixes cannot collide.
                let target = "\(track.nodeID.utf8.count):\(track.nodeID):\(track.channel.rawValue)"
                guard targets.insert(target).inserted else {
                    throw .init(.invalidTrack, itemID: track.id, message: "Multiple tracks write the same node channel.")
                }
                let node = binding.nodes[index]
                let width = track.channel == .weights ? node.morphRestWeights?.count ?? 0 : track.channel == .rotation ? 4 : 3
                guard width > 0, track.channel == .weights || node.restTranslation != nil,
                    !(track.channel == .weights && track.interpolation == .cubicSpline && track.keys.count == 1) else {
                    throw .init(.invalidTrack, itemID: track.id, message: "Track channel is incompatible with its binding.")
                }
                keyCount += track.keys.count
                guard keyCount <= 100_000 else {
                    throw .init(.limitExceeded, itemID: track.id, message: "A library supports at most 100000 keys.")
                }
                try validateIdentities(track.keys.map(\.id))
                var previous: Double = -1
                for key in track.keys {
                    guard key.time.isFinite, key.time >= 0, key.time <= clip.duration, key.time > previous,
                        key.value.count == width, key.value.allSatisfy(\.isFinite) else {
                        throw .init(.invalidKey, itemID: key.id, message: "Keys need finite ordered times within the duration and correctly typed values.")
                    }
                    previous = key.time
                    if track.channel == .rotation, abs(key.value.reduce(Float(0)) { $0 + $1 * $1 } - 1) >= 0.001 {
                        throw .init(.invalidKey, itemID: key.id, message: "Rotation keys need normalized XYZW quaternions.")
                    }
                    for tangent in [key.incoming, key.outgoing] {
                        if let tangent {
                            guard tangent.count == width, tangent.allSatisfy(\.isFinite) else {
                                throw .init(.invalidKey, itemID: key.id, message: "Tangent dimensions and values must match the channel.")
                            }
                        } else if track.interpolation == .cubicSpline {
                            throw .init(.invalidKey, itemID: key.id, message: "Cubic keys need incoming and outgoing derivatives.")
                        }
                    }
                }
                curveComponents += CompiledAnimationCurves.componentCount(for: track, width: width)
                guard curveComponents <= Self.maximumCurveComponents else {
                    throw .init(.limitExceeded, itemID: track.id, message: "Native curves support at most 500000 compiled scalar segments per library.")
                }
                do { _ = try CompiledAnimationCurves.make(track, width: width) }
                catch { throw .init(.invalidCurve, itemID: track.id, message: "Invalid temporal curve: \(error).") }
            }
        }
    }

    private func validateText(_ text: String, maximum: Int, itemID: String) throws(AnimationAuthoringError) {
        guard text.utf8.count <= maximum else {
            throw .init(.limitExceeded, itemID: itemID, message: "Metadata exceeds its \(maximum) UTF-8 byte limit.")
        }
    }

    private func validateIdentities(_ identities: [String]) throws(AnimationAuthoringError) {
        var seen: Set<String> = []
        for identity in identities {
            guard !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, identity.utf8.count <= 256 else {
                throw .init(.invalidIdentity, itemID: identity, message: "IDs must be nonempty and at most 256 UTF-8 bytes.")
            }
            guard seen.insert(identity).inserted else {
                throw .init(.duplicateIdentity, itemID: identity, message: "Duplicate authored ID: \(identity).")
            }
        }
    }
}
