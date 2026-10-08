import Foundation

extension NativeGLTFLoader {
    func importAnimations(_ gltf: GLTF, buffers: [Data]) throws -> [GLTFImportResult.Animation] {
        let nodes = gltf.nodes ?? []
        return try (gltf.animations ?? []).enumerated().map { index, animation in
            guard !animation.samplers.isEmpty, !animation.channels.isEmpty else { throw GLTFError.invalidAnimation(index) }
            let samplers = try animation.samplers.map { sampler in
                let input = try checkedAccessor(sampler.input, gltf: gltf)
                let output = try checkedAccessor(sampler.output, gltf: gltf)
                guard input.type == "SCALAR", input.componentType == 5126, input.normalized != true,
                    output.componentType == 5126, output.normalized != true,
                    let interpolation = GLTFImportResult.AnimationInterpolation(rawValue: sampler.interpolation ?? "LINEAR")
                else {
                    throw GLTFError.invalidAnimation(index)
                }
                let times = try decodeAccessor(sampler.input, gltf: gltf, buffers: buffers).values.map(Float.init)
                guard !times.isEmpty, times.allSatisfy({ $0.isFinite && $0 >= 0 }),
                    zip(times, times.dropFirst()).allSatisfy({ $0 < $1 })
                else {
                    throw GLTFError.invalidAnimation(index)
                }
                let decoded = try decodeAccessor(sampler.output, gltf: gltf, buffers: buffers)
                guard decoded.values.allSatisfy(\.isFinite) else { throw GLTFError.invalidAnimation(index) }
                return GLTFImportResult.AnimationSampler(
                    times: times,
                    output: GLTFImportResult.Accessor(values: decoded.values.map(Float.init), componentCount: decoded.componentCount),
                    interpolation: interpolation
                )
            }
            var targets: Set<String> = []
            let channels = try animation.channels.map { channel in
                guard let path = GLTFImportResult.AnimationPath(rawValue: channel.target.path) else {
                    throw GLTFError.unsupportedAnimationPath(channel.target.path)
                }
                guard let node = channel.target.node, nodes.indices.contains(node), nodes[node].matrix == nil,
                    samplers.indices.contains(channel.sampler), targets.insert("\(node):\(path.rawValue)").inserted
                else {
                    throw GLTFError.invalidAnimation(index)
                }
                let sampler = samplers[channel.sampler]
                let output = try checkedAccessor(animation.samplers[channel.sampler].output, gltf: gltf)
                let isCubic = sampler.interpolation == .cubicSpline
                guard output.type == (path == .rotation ? "VEC4" : "VEC3"),
                    sampler.output.count == sampler.times.count * (isCubic ? 3 : 1),
                    !isCubic || sampler.times.count >= 2
                else {
                    throw GLTFError.invalidAnimation(index)
                }
                if path == .rotation {
                    for key in sampler.times.indices {
                        let offset = (key * (isCubic ? 3 : 1) + (isCubic ? 1 : 0)) * 4
                        let quaternion = sampler.output.values[offset..<offset + 4]
                        guard abs(quaternion.reduce(0) { $0 + $1 * $1 } - 1) < 0.001 else {
                            throw GLTFError.invalidAnimation(index)
                        }
                    }
                }
                return GLTFImportResult.AnimationChannel(samplerIndex: channel.sampler, nodeIndex: node, path: path)
            }
            return GLTFImportResult.Animation(name: animation.name, samplers: samplers, channels: channels)
        }
    }
}
