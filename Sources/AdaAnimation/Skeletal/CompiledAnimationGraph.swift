import Math

/// Per-player evaluation buffers; compilation resolves IDs and expands masks once.
struct CompiledAnimationGraph: Sendable {
    var graph: AnimationGraph
    let root: Int
    let order: [Int]
    let inputs: [[Int]]
    let masks: [[[Float]]]
    let clipIndices: [Int?]
    let rest: [SkeletalJointPose]
    var poses: [[SkeletalJointPose]]
    var contributions: [Float]
    let duration: Double
    let loops: Bool

    init(graph: AnimationGraph, rig: SkeletalRig, clips: [SkeletalAnimationClip]) throws(AnimationGraphError) {
        guard !graph.nodes.isEmpty, graph.nodes.count <= 256 else { throw .invalidNode(graph.root) }
        var indices: [String: Int] = [:]
        for (index, node) in graph.nodes.enumerated() {
            guard !node.id.isEmpty, indices.updateValue(index, forKey: node.id) == nil,
                node.speed.isFinite, node.inputs.count <= 64, node.events.count <= 256
            else { throw .invalidNode(node.id) }
            guard node.kind == .clip ? node.inputs.isEmpty : !node.inputs.isEmpty else { throw .invalidNode(node.id) }
            guard node.kind == .clip || node.events.isEmpty else { throw .invalidEvent(node.id) }
        }
        guard let root = indices[graph.root] else { throw .missingNode(graph.root) }
        var inputs: [[Int]] = []
        var masks: [[[Float]]] = []
        var clipIndices: [Int?] = []
        for node in graph.nodes {
            var links: [Int] = []
            var expanded: [[Float]] = []
            for input in node.inputs {
                guard let target = indices[input.node] else { throw .missingNode(input.node) }
                guard input.weight.isFinite, (0...1_000).contains(input.weight) else { throw .invalidWeight }
                links.append(target)
                expanded.append(try Self.expand(input.mask, rig: rig))
            }
            inputs.append(links)
            masks.append(expanded)
            if node.kind == .clip {
                guard let index = clips.firstIndex(where: { $0.name == node.clip }) else { throw .missingClip(node.clip) }
                for event in node.events {
                    guard !event.name.isEmpty, event.time.isFinite, event.time >= 0, event.time <= clips[index].duration else {
                        throw .invalidEvent(event.name)
                    }
                }
                clipIndices.append(index)
            } else {
                clipIndices.append(nil)
            }
        }
        var states = [UInt8](repeating: 0, count: graph.nodes.count)
        var allOrder: [Int] = []
        func visit(_ index: Int) throws(AnimationGraphError) {
            if states[index] == 1 { throw .cycle(graph.nodes[index].id) }
            if states[index] == 2 {
                return
            }
            states[index] = 1
            for child in inputs[index] { try visit(child) }
            states[index] = 2
            allOrder.append(index)
        }
        // Reject invalid disconnected subgraphs too; only the output's subgraph is evaluated.
        try visit(root)
        let order = allOrder
        for index in graph.nodes.indices { try visit(index) }
        let rest = rig.nodes.map { $0.restPose ?? SkeletalJointPose() }
        self.graph = graph
        self.root = root
        self.order = order
        self.inputs = inputs
        self.masks = masks
        self.clipIndices = clipIndices
        self.rest = rest
        self.poses = graph.nodes.map { _ in rest }
        self.contributions = [Float](repeating: 0, count: graph.nodes.count)
        var duration: Double = 0
        var loops = false
        for index in order {
            if let clip = clipIndices[index], graph.nodes[index].speed != 0 {
                let span = clips[clip].duration / abs(graph.nodes[index].speed)
                guard span.isFinite else { throw .invalidNode(graph.nodes[index].id) }
                duration = max(duration, span)
                loops = loops || graph.nodes[index].repeats && clips[clip].duration > 0
            }
        }
        self.duration = duration
        self.loops = loops
    }

    private static func expand(_ mask: AnimationGraph.Mask?, rig: SkeletalRig) throws(AnimationGraphError) -> [Float] {
        guard let mask else {
            return [Float](repeating: 1, count: rig.nodes.count)
        }
        guard mask.defaultWeight.isFinite, (0...1).contains(mask.defaultWeight) else { throw .invalidWeight }
        var weights = [Float](repeating: mask.defaultWeight, count: rig.nodes.count)
        for joint in mask.joints {
            guard rig.nodes.indices.contains(joint.nodeIndex) else { throw .invalidMask(joint.nodeIndex) }
            guard joint.weight.isFinite, (0...1).contains(joint.weight) else { throw .invalidWeight }
            for index in rig.evaluationOrder {
                var ancestor: Int? = index
                while let current = ancestor {
                    if current == joint.nodeIndex {
                        weights[index] = joint.weight
                        break
                    }
                    if !joint.includesDescendants { break }
                    ancestor = rig.nodes[current].parentIndex
                }
            }
        }
        return weights
    }

    mutating func evaluate(time: Double, clips: [SkeletalAnimationClip]) {
        for index in order {
            let node = graph.nodes[index]
            if let clipIndex = clipIndices[index] {
                for joint in rest.indices { poses[index][joint] = rest[joint] }
                let clip = clips[clipIndex]
                let clock = Self.clipTime(time, node: node, duration: clip.duration)
                let remainder = clip.duration > 0 ? clock.truncatingRemainder(dividingBy: clip.duration) : 0
                let local = node.repeats ? (remainder < 0 ? remainder + clip.duration : remainder) : min(max(clock, 0), clip.duration)
                for track in clip.tracks {
                    let value = track.sample(at: local)
                    switch track.path {
                    case .translation: poses[index][track.nodeIndex].translation = value.xyz
                    case .rotation: poses[index][track.nodeIndex].rotation = Quat(x: value.x, y: value.y, z: value.z, w: value.w)
                    case .scale: poses[index][track.nodeIndex].scale = value.xyz
                    }
                }
            } else {
                for joint in rest.indices {
                    poses[index][joint] = node.kind == .blend ? blend(index, joint: joint) : additive(index, joint: joint)
                }
            }
        }
    }

    private func blend(_ index: Int, joint: Int) -> SkeletalJointPose {
        let node = graph.nodes[index]
        var total: Float = 0
        var reference = rest[joint].rotation
        var hasReference = false
        for edge in node.inputs.indices {
            let weight = node.inputs[edge].weight * masks[index][edge][joint]
            total += weight
            if weight > 0 && !hasReference {
                reference = poses[inputs[index][edge]][joint].rotation
                hasReference = true
            }
        }
        let denominator = max(1, total)
        let restWeight = max(0, 1 - total)
        var translation = rest[joint].translation * restWeight
        var scale = rest[joint].scale * restWeight
        let restRotation = rest[joint].rotation
        let restSign: Float = restRotation.dot(reference) < 0 ? -1 : 1
        let restAmount = restWeight * restSign
        var rotation: Vector4 = Vector4(restRotation.x, restRotation.y, restRotation.z, restRotation.w) * restAmount
        for edge in node.inputs.indices {
            let weight = node.inputs[edge].weight * masks[index][edge][joint]
            let pose = poses[inputs[index][edge]][joint]
            translation += pose.translation * weight
            scale += pose.scale * weight
            let sign: Float = pose.rotation.dot(reference) < 0 ? -1 : 1
            rotation += Vector4(pose.rotation.x, pose.rotation.y, pose.rotation.z, pose.rotation.w) * (weight * sign)
        }
        let quaternion = Quat(x: rotation.x, y: rotation.y, z: rotation.z, w: rotation.w)
        return SkeletalJointPose(translation: translation / denominator, rotation: quaternion.squaredLength > 0.000001 ? quaternion.normalized : reference, scale: scale / denominator)
    }

    private func additive(_ index: Int, joint: Int) -> SkeletalJointPose {
        let node = graph.nodes[index]
        let base = poses[inputs[index][0]][joint]
        let amount = min(1, node.inputs[0].weight * masks[index][0][joint])
        var result = SkeletalJointPose(
            translation: rest[joint].translation + (base.translation - rest[joint].translation) * amount,
            rotation: slerpQuat(rest[joint].rotation, base.rotation, t: amount),
            scale: rest[joint].scale + (base.scale - rest[joint].scale) * amount
        )
        for edge in node.inputs.indices.dropFirst() {
            let weight = min(1, node.inputs[edge].weight * masks[index][edge][joint])
            let pose = poses[inputs[index][edge]][joint]
            result.translation += (pose.translation - rest[joint].translation) * weight
            let reference = rest[joint].rotation
            let inverse = Quat(x: -reference.x, y: -reference.y, z: -reference.z, w: reference.w)
            let delta = multiply(inverse, pose.rotation)
            result.rotation = multiply(result.rotation, slerpQuat(.identity, delta, t: weight)).normalized
            for axis in 0..<3 {
                let scale = rest[joint].scale[axis]
                if abs(scale) > 0.000001 {
                    result.scale[axis] *= 1 + (pose.scale[axis] / scale - 1) * weight
                } else {
                    result.scale[axis] += (pose.scale[axis] - scale) * weight
                }
            }
        }
        return result
    }

    private func multiply(_ a: Quat, _ b: Quat) -> Quat {
        Quat(
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }

    static func clipTime(_ time: Double, node: AnimationGraph.Node, duration: Double) -> Double {
        let value = time * node.speed + (node.speed < 0 ? duration : 0)
        return value.isFinite ? value : 0
    }
}
