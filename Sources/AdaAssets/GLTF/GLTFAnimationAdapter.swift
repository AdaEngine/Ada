import AdaAnimation
import Math

/// Shared CPU conversion for imported model playback and animation authoring.
public enum GLTFAnimationAdapter {
    /// The weights a node's mesh has when nothing animates them, or `nil` when it has no morph targets.
    private static func restWeights(of node: GLTFImportResult.Node, meshes: [GLTFImportResult.Mesh]) -> [Float]? {
        guard let meshIndex = node.meshIndex, meshes.indices.contains(meshIndex), meshes[meshIndex].morphTargetCount > 0 else { return nil }
        return node.weights ?? meshes[meshIndex].defaultWeights
    }

    public static func makeRig(nodes: [GLTFImportResult.Node], meshes: [GLTFImportResult.Mesh] = []) throws -> SkeletalRig {
        var parents = [Int?](repeating: nil, count: nodes.count)
        for (index, node) in nodes.enumerated() {
            for child in node.children {
                guard nodes.indices.contains(child), parents[child] == nil else { throw SkeletalAnimationError.invalidHierarchy }
                parents[child] = index
            }
        }
        return try SkeletalRig(nodes: nodes.enumerated().map { index, node in
            let pose = node.restPose.map { SkeletalJointPose(translation: $0.translation, rotation: $0.rotation, scale: $0.scale) }
            return SkeletalRig.Node(
                parentIndex: parents[index],
                restPose: pose,
                restMatrix: node.transform,
                name: node.name,
                morphRestWeights: restWeights(of: node, meshes: meshes)
            )
        })
    }

    public static func makeClips(
        _ clips: [GLTFImportResult.Animation],
        nodes: [GLTFImportResult.Node] = [],
        meshes: [GLTFImportResult.Mesh] = []
    ) throws -> [SkeletalAnimationClip] {
        try clips.enumerated().map { index, clip in
            // Weight channels become morph tracks; the others are pose tracks.
            let tracks = try clip.channels.filter { $0.path != .weights }.map { channel in
                guard clip.samplers.indices.contains(channel.samplerIndex) else { throw SkeletalAnimationError.invalidTrack }
                let sampler = clip.samplers[channel.samplerIndex]
                guard sampler.output.componentCount == (channel.path == .rotation ? 4 : 3) else { throw SkeletalAnimationError.invalidTrack }
                let path: SkeletalAnimationTrack.Path
                switch channel.path {
                case .translation: path = .translation
                case .rotation: path = .rotation
                case .scale: path = .scale
                case .weights: preconditionFailure("Weight channels are filtered out above.")
                }
                let interpolation: SkeletalAnimationTrack.Interpolation
                switch sampler.interpolation {
                case .linear: interpolation = .linear
                case .step: interpolation = .step
                case .cubicSpline: interpolation = .cubicSpline
                }
                let values: [Vector4] = sampler.output.componentCount == 4
                    ? sampler.output.vector4Values()
                    : sampler.output.vector3Values().map { Vector4($0, 0) }
                return try SkeletalAnimationTrack(
                    nodeIndex: channel.nodeIndex, path: path, interpolation: interpolation, times: sampler.times.map(Double.init), values: values
                )
            }
            let morphTracks = try clip.channels.filter { $0.path == .weights }.map { channel in
                guard clip.samplers.indices.contains(channel.samplerIndex) else { throw SkeletalAnimationError.invalidTrack }
                let sampler = clip.samplers[channel.samplerIndex]
                guard sampler.output.componentCount == 1 else { throw SkeletalAnimationError.invalidTrack }
                let interpolation: SkeletalAnimationTrack.Interpolation
                switch sampler.interpolation {
                case .linear: interpolation = .linear
                case .step: interpolation = .step
                case .cubicSpline: interpolation = .cubicSpline
                }
                let targets = nodes.indices.contains(channel.nodeIndex) ? Self.restWeights(of: nodes[channel.nodeIndex], meshes: meshes)?.count ?? 0 : 0
                return try MorphWeightsTrack(
                    nodeIndex: channel.nodeIndex,
                    interpolation: interpolation,
                    times: sampler.times.map(Double.init),
                    targetCount: targets,
                    values: sampler.output.values
                )
            }
            return SkeletalAnimationClip(name: clip.name ?? "Animation \(index)", tracks: tracks, morphTracks: morphTracks)
        }
    }
}
