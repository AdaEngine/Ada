import AdaAnimation
import AdaAssets
import Math

extension ModelAsset3D {
    static func makeRig(nodes: [GLTFImportResult.Node]) throws -> SkeletalRig {
        var parents = [Int?](repeating: nil, count: nodes.count)
        for (index, node) in nodes.enumerated() {
            for child in node.children {
                guard nodes.indices.contains(child), parents[child] == nil else { throw SkeletalAnimationError.invalidHierarchy }
                parents[child] = index
            }
        }
        return try SkeletalRig(nodes: nodes.enumerated().map { index, node in
            let pose = node.restPose.map { SkeletalJointPose(translation: $0.translation, rotation: $0.rotation, scale: $0.scale) }
            return SkeletalRig.Node(parentIndex: parents[index], restPose: pose, restMatrix: node.transform)
        })
    }

    static func makeClips(_ clips: [GLTFImportResult.Animation]) throws -> [SkeletalAnimationClip] {
        try clips.enumerated().map { index, clip in
            let tracks = try clip.channels.map { channel in
                let sampler = clip.samplers[channel.samplerIndex]
                let path: SkeletalAnimationTrack.Path
                switch channel.path {
                case .translation: path = .translation
                case .rotation: path = .rotation
                case .scale: path = .scale
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
            return SkeletalAnimationClip(name: clip.name ?? "Animation \(index)", tracks: tracks)
        }
    }
}
