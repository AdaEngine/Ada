import Foundation
import Math

extension AnimationRigBinding {
    /// Captures identities for this imported hierarchy. Later reimports must pass full snapshot compatibility.
    public init(rig: SkeletalRig, sourceAsset: String) {
        self.init(sourceAsset: sourceAsset, nodes: Self.capture(rig, ids: rig.nodes.indices.map { "node-\($0)" }))
    }

    /// Restores the saved rig for detached sampling without touching a scene or source asset.
    public func makeRig() throws -> SkeletalRig {
        try AnimationLibrary(binding: self).validate()
        let indices = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        return try SkeletalRig(nodes: nodes.map { node in
            let pose: SkeletalJointPose?
            if let translation = node.restTranslation, let rotation = node.restRotation, let scale = node.restScale {
                pose = .init(translation: translation, rotation: Quat(x: rotation.x, y: rotation.y, z: rotation.z, w: rotation.w), scale: scale)
            } else { pose = nil }
            return .init(parentIndex: node.parentID.flatMap { indices[$0] }, restPose: pose, restMatrix: node.restMatrix,
                         name: node.name, morphRestWeights: node.morphRestWeights)
        })
    }

    /// Checks full hierarchy/rest data, not just names or a potentially colliding hash.
    public func isCompatible(with rig: SkeletalRig) -> Bool {
        nodes.count == rig.nodes.count && nodes == Self.capture(rig, ids: nodes.map(\.id))
    }

    private static func capture(_ rig: SkeletalRig, ids: [String]) -> [Node] {
        rig.nodes.enumerated().map { index, node in
            let rotation = node.restPose.map { Vector4($0.rotation.x, $0.rotation.y, $0.rotation.z, $0.rotation.w) }
            return Node(id: ids[index], name: node.name, parentID: node.parentIndex.map { ids[$0] }, restMatrix: node.restMatrix,
                        restTranslation: node.restPose?.translation, restRotation: rotation, restScale: node.restPose?.scale,
                        morphRestWeights: node.morphRestWeights)
        }
    }
}

extension AnimationLibrary {
    /// Extracts an editable copy of a runtime/imported clip, preserving glTF cubic derivatives and morph keys.
    public mutating func extract(_ source: SkeletalAnimationClip, rig: SkeletalRig, id clipID: String = UUID().uuidString,
                                 name: String? = nil, sourceFingerprint: String? = nil) throws {
        guard binding.isCompatible(with: rig) else {
            throw AnimationAuthoringError(.incompatibleRig, itemID: id, message: "The source hierarchy/rest pose has changed; remap explicitly.")
        }
        var tracks: [AnimationLibraryTrack] = []
        for track in source.tracks {
            guard binding.nodes.indices.contains(track.nodeIndex), let channel = AnimationLibraryTrack.Channel(rawValue: track.path.rawValue),
                let interpolation = track.authoredCurves?.interpolation ?? AnimationLibraryTrack.Interpolation(rawValue: track.interpolation.rawValue) else {
                throw AnimationAuthoringError(.invalidTrack, itemID: clipID, message: "Source track has an unsupported target/channel.")
            }
            let width = channel == .rotation ? 4 : 3
            let values = track.values.map { Array([$0.x, $0.y, $0.z, $0.w].prefix(width)) }
            tracks.append(.init(nodeID: binding.nodes[track.nodeIndex].id, channel: channel, interpolation: interpolation,
                                keys: Self.importKeys(times: track.times, rows: values, cubic: interpolation == .cubicSpline, curves: track.authoredCurves?.metadata)))
        }
        for track in source.morphTracks {
            guard binding.nodes.indices.contains(track.nodeIndex),
                let interpolation = track.authoredCurves?.interpolation ?? AnimationLibraryTrack.Interpolation(rawValue: track.interpolation.rawValue) else {
                throw AnimationAuthoringError(.invalidTrack, itemID: clipID, message: "Source morph track has an invalid target.")
            }
            let width = track.targetCount
            let rows = stride(from: 0, to: track.values.count, by: width).map { Array(track.values[$0..<($0 + width)]) }
            tracks.append(.init(nodeID: binding.nodes[track.nodeIndex].id, channel: .weights, interpolation: interpolation,
                                keys: Self.importKeys(times: track.times, rows: rows, cubic: interpolation == .cubicSpline, curves: track.authoredCurves?.metadata)))
        }
        var draft = self
        draft.clips.append(.init(id: clipID, name: name ?? source.name, duration: source.duration, sourceClip: source.name,
                                 sourceFingerprint: sourceFingerprint, tracks: tracks))
        draft.promoteNativeCurveFormat()
        try draft.validate()
        self = draft
    }

    /// Qualified runtime names distinguish authored clip IDs from display labels.
    /// Hosts must reject any collisions when merging authored and arbitrarily named imported clips.
    public func runtimeName(for clipID: String) -> String {
        "animlib:\(id.utf8.count):\(id):\(clipID)"
    }

    /// Validates once and compiles to the existing allocation-free skeletal and morph samplers.
    /// An unchanged player reuses these tracks; no binding lookup runs per sampled key.
    public func compiledClips(for rig: SkeletalRig) throws -> [SkeletalAnimationClip] {
        try validate()
        guard binding.isCompatible(with: rig) else {
            throw AnimationAuthoringError(.incompatibleRig, itemID: id, message: "The animation library needs an explicit rig remap.")
        }
        let indices = Dictionary(uniqueKeysWithValues: binding.nodes.enumerated().map { ($0.element.id, $0.offset) })
        return try clips.map { clip in
            var poseTracks: [SkeletalAnimationTrack] = []
            var morphTracks: [MorphWeightsTrack] = []
            for track in clip.tracks where !track.keys.isEmpty {
                guard let node = indices[track.nodeID] else {
                    throw AnimationAuthoringError(.missingTarget, itemID: track.id, message: "Track binding cannot be resolved.")
                }
                let interpolation: SkeletalAnimationTrack.Interpolation
                switch track.interpolation {
                case .linear: interpolation = .linear
                case .bezier: interpolation = .bezier
                case .step: interpolation = .step
                case .cubicSpline: interpolation = .cubicSpline
                }
                let curves = try CompiledAnimationCurves.make(track, width: track.keys[0].value.count)
                let rows = track.keys.flatMap { key -> [[Float]] in
                    if track.interpolation == .cubicSpline { return [key.incoming ?? [], key.value, key.outgoing ?? []] }
                    return [key.value]
                }
                if track.channel == .weights {
                    var runtime = try MorphWeightsTrack(nodeIndex: node, interpolation: interpolation, times: track.keys.map(\.time),
                                                        targetCount: binding.nodes[node].morphRestWeights?.count ?? 0, values: rows.flatMap { $0 })
                    runtime.authoredCurves = curves
                    morphTracks.append(runtime)
                } else {
                    guard let path = SkeletalAnimationTrack.Path(rawValue: track.channel.rawValue) else {
                        throw AnimationAuthoringError(.invalidTrack, itemID: track.id, message: "Track channel cannot be compiled.")
                    }
                    let values = rows.map { Vector4($0[0], $0[1], $0[2], $0.count == 4 ? $0[3] : 0) }
                    var runtime = try SkeletalAnimationTrack(nodeIndex: node, path: path, interpolation: interpolation,
                                                            times: track.keys.map(\.time), values: values)
                    runtime.authoredCurves = curves
                    poseTracks.append(runtime)
                }
            }
            return try .init(name: runtimeName(for: clip.id), tracks: poseTracks, morphTracks: morphTracks, duration: clip.duration)
        }
    }

    /// Samples a detached clip without events, gameplay callbacks or scene mutation.
    public func sample(clipID: String, at time: Double) throws -> SkeletalAnimationPlayer {
        guard time.isFinite else {
            throw AnimationAuthoringError(.invalidKey, itemID: clipID, message: "Sample time must be finite.")
        }
        guard let clip = clips.first(where: { $0.id == clipID }) else {
            throw AnimationAuthoringError(.missingClip, itemID: clipID, message: "Clip does not exist.")
        }
        let rig = try binding.makeRig()
        var player = try SkeletalAnimationPlayer(rig: rig, clips: compiledClips(for: rig))
        player.repeats = clip.repeats
        try player.play(runtimeName(for: clipID), transitionDuration: 0)
        player.seek(to: time)
        player.isPlaying = false
        return player
    }

    private static func importKeys(times: [Double], rows: [[Float]], cubic: Bool, curves: [AnimationKeyCurve?]? = nil) -> [AnimationLibraryKey] {
        times.enumerated().map { index, time in
            let offset = index * (cubic ? 3 : 1)
            return .init(time: time, value: rows[offset + (cubic ? 1 : 0)], incoming: cubic ? rows[offset] : nil,
                         outgoing: cubic ? rows[offset + 2] : nil, curve: curves.flatMap { $0[index] })
        }
    }
}
