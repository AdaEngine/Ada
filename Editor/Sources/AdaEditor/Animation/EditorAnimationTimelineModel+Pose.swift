@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

extension EditorAnimationTimelineModel {
    func sampledValues(_ channel: AnimationLibraryTrack.Channel, nodeID: String? = nil) -> [Float] {
        guard let library, let clip, let id = nodeID ?? selectedNode?.id,
              let index = library.binding.nodes.firstIndex(where: { $0.id == id }) else { return [] }
        if let draft = poseValues[id + ":" + channel.rawValue] { return draft }
        guard let sampled = workspace?.preview.capturedAnimationPlayer() ?? (try? library.sample(clipID: clip.id, at: time)),
              sampled.poses.indices.contains(index) else { return [] }
        let pose = sampled.poses[index]
        switch channel {
        case .translation: return [pose.translation.x, pose.translation.y, pose.translation.z]
        case .rotation: return [pose.rotation.x, pose.rotation.y, pose.rotation.z, pose.rotation.w]
        case .scale: return [pose.scale.x, pose.scale.y, pose.scale.z]
        case .weights: return []
        }
    }

    /// Inverse of Math.Quat.euler's existing Y, X, Z argument convention.
    static func eulerDegrees(_ values: [Float]) -> [Float] {
        guard values.count == 4 else { return [] }
        let length: Double = values.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard length > 0, length.isFinite else { return [] }
        let x = Double(values[0]) / length, y = Double(values[1]) / length
        let z = Double(values[2]) / length, w = Double(values[3]) / length
        let r00 = 1 - 2 * (y * y + z * z), r01 = 2 * (x * y - w * z)
        let r02 = 2 * (x * z + w * y), r12 = 2 * (y * z - w * x), r22 = 1 - 2 * (x * x + y * y)
        let cosine = (r00 * r00 + r01 * r01).squareRoot()
        let b = Foundation.atan2(r02, cosine)
        let a = cosine > 0.000001 ? Foundation.atan2(-r12, r22) : 2 * Foundation.atan2(x, w)
        let c = cosine > 0.000001 ? Foundation.atan2(-r01, r00) : 0
        return [b, a, c].map { Float($0 * 180 / .pi) }
    }

    func requirePoseTarget() throws {
        guard let poseIdentity else { return }
        guard poseIdentity.library == library?.id, poseIdentity.clip == clip?.id,
              abs(poseIdentity.time - time) < 0.0000001,
              poseIdentity.revision == workspace?.library?.revision else {
            throw AnimationAuthoringError(.conflict, itemID: "pose", message: L10n.tr("Insert or discard the unkeyed pose first."))
        }
    }

    func setPose(_ channel: AnimationLibraryTrack.Channel, values: [Float], components: Set<Int>? = nil, euler: Bool = false) throws {
        guard isEditable, !selectedNodes.isEmpty, let workspace, let library, let clip else { return }
        guard !workspace.isWorking, !workspace.isChangingLibrary else {
            throw AnimationAuthoringError(.conflict, itemID: "pose", message: L10n.tr("Wait for the current animation operation to finish."))
        }
        try requirePoseTarget()
        let sampled = try library.sample(clipID: clip.id, at: time)
        var pose = try library.poseClip(name: "__EditorPose_" + UUID().uuidString, duration: max(0.001, duration), from: sampled)
        var proposed = poseValues
        for id in selectedNodes {
            var result = sampledValues(channel, nodeID: id)
            if euler { result = Self.eulerDegrees(result) }
            guard result.count == values.count else { continue }
            for index in result.indices where components == nil || components?.contains(index) == true { result[index] = values[index] }
            if euler {
                let rotation = Quat.euler(Vector3(result[0], result[1], result[2]) * (Float.pi / 180)).normalized
                result = [rotation.x, rotation.y, rotation.z, rotation.w]
            }
            proposed[id + ":" + channel.rawValue] = result
        }
        for index in pose.tracks.indices {
            let track = pose.tracks[index]
            guard let value = proposed[track.nodeID + ":" + track.channel.rawValue], !track.keys.isEmpty else { continue }
            pose.tracks[index].keys[0].value = value
        }
        var draft = library
        draft.clips.append(pose)
        try draft.validate()
        let clock = time
        try workspace.preview.installAnimationLibraries([draft])
        workspace.preview.playsAnimation = false
        workspace.preview.animationGraph = nil
        workspace.preview.selectedAnimation = draft.runtimeName(for: pose.id)
        workspace.preview.seekGraph(to: clock)
        poseValues = proposed
        if poseRevision == nil { poseRevision = workspace.library?.revision }
        if poseIdentity == nil { poseIdentity = .init(library: library.id, clip: clip.id, time: clock, revision: workspace.library?.revision ?? "") }
        if autoKey { try insertKeys(channels: [channel]) }
    }
}
