import Math

/// Compiles stable IDs once; each player owns its own stack and scratch storage.
struct CompiledPoseModifiers: Sendable {
    struct Entry: Sendable {
        var configuration: AnimationPoseModifier
        var joints: [Int]
    }
    var entries: [Entry]
    private var positions: [Vector3]
    private var lengths: [Float]
    private var rotations: [Quat]
    private var bestPositions: [Vector3]

    init(_ modifiers: [AnimationPoseModifier], rig: SkeletalRig, binding: AnimationRigBinding) throws(AnimationPoseModifierError) {
        guard Set(binding.nodes.map(\.id)).count == binding.nodes.count,
              binding.nodes.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 }),
              binding.isCompatible(with: rig) else { throw .incompatibleRig }
        guard modifiers.count <= 32 else { throw .limitExceeded }
        let indices = Dictionary(uniqueKeysWithValues: binding.nodes.enumerated().map { ($0.element.id, $0.offset) })
        var restGlobals = Array(repeating: Transform3D.identity, count: rig.nodes.count)
        for index in rig.evaluationOrder {
            let local = rig.nodes[index].restPose?.matrix ?? rig.nodes[index].restMatrix
            restGlobals[index] = rig.nodes[index].parentIndex.map { restGlobals[$0] * local } ?? local
        }
        var ids = Set<String>()
        var budget = 0
        var compiled: [Entry] = []
        for modifier in modifiers {
            guard !modifier.id.isEmpty, modifier.id.utf8.count <= 256, ids.insert(modifier.id).inserted,
                  modifier.name.map({ $0.utf8.count <= 256 }) ?? true,
                  IKMath.finite(modifier.target), modifier.pole.map(IKMath.finite) ?? true,
                  modifier.influence.isFinite, (0...1).contains(modifier.influence),
                  (1...64).contains(modifier.iterations),
                  modifier.tolerance.map({ $0.isFinite && $0 > 0 }) ?? true else { throw .invalidModifier(modifier.id) }
            guard (2...65).contains(modifier.joints.count),
                  modifier.kind != .twoBone || modifier.joints.count == 3 else { throw .invalidChain(modifier.id) }
            let joints = modifier.joints.compactMap { indices[$0] }
            guard joints.count == modifier.joints.count, Set(joints).count == joints.count,
                  joints.allSatisfy({ rig.nodes[$0].restPose != nil }),
                  zip(joints, joints.dropFirst()).allSatisfy({ rig.nodes[$1].parentIndex == $0 }) else { throw .invalidChain(modifier.id) }
            guard zip(joints, joints.dropFirst()).allSatisfy({
                let length = IKMath.length(restGlobals[$1].origin - restGlobals[$0].origin)
                return length.isFinite && length > 1e-8
            }) else { throw .invalidChain(modifier.id) }
            budget += (joints.count - 1) * (modifier.kind == .twoBone ? 1 : modifier.iterations)
            guard budget <= 32_768 else { throw .limitExceeded }
            compiled.append(Entry(configuration: modifier, joints: joints))
        }
        entries = compiled
        let capacity = compiled.map { $0.joints.count }.max() ?? 0
        positions = Array(repeating: .zero, count: capacity)
        lengths = Array(repeating: 0, count: capacity)
        rotations = Array(repeating: .identity, count: capacity)
        bestPositions = Array(repeating: .zero, count: capacity)
    }

    mutating func apply(rig: SkeletalRig, inputs: [String: AnimationPoseModifierInput], poses: inout [SkeletalJointPose], locals: inout [Transform3D],
                        globals: inout [Transform3D], diagnostics: inout [AnimationPoseModifierDiagnostic]) {
        diagnostics.removeAll(keepingCapacity: true)
        for entry in entries {
            var configuration = entry.configuration
            var result = AnimationPoseModifierDiagnostic(id: configuration.id, status: .disabled, iterations: 0)
            guard configuration.enabled else { diagnostics.append(result); continue }
            if let input = inputs[configuration.id] {
                guard input.supportsTransform else { result.status = .unsupportedTransform; diagnostics.append(result); continue }
                guard let target = input.target, IKMath.finite(target), input.pole.map(IKMath.finite) ?? true else {
                    result.status = .invalidTarget; diagnostics.append(result); continue
                }
                configuration.target = target
                configuration.pole = input.pole ?? configuration.pole
            }
            let count = entry.joints.count
            var valid = true
            // Validate only the participating branch, including the current ancestor transforms.
            var ancestor: Int? = entry.joints[count - 1]
            while let index = ancestor {
                if !IKMath.supported(locals[index]) || !IKMath.supported(globals[index]) { valid = false; break }
                ancestor = rig.nodes[index].parentIndex
            }
            guard valid else { result.status = .unsupportedTransform; diagnostics.append(result); continue }
            for offset in 0..<count {
                positions[offset] = globals[entry.joints[offset]].origin
                rotations[offset] = poses[entry.joints[offset]].rotation
                if offset > 0 {
                    lengths[offset - 1] = IKMath.length(positions[offset] - positions[offset - 1])
                    valid = valid && lengths[offset - 1].isFinite && lengths[offset - 1] > 1e-8
                }
            }
            guard valid, IKMath.length(configuration.target - positions[0]).isFinite else {
                result.status = .invalidPose; diagnostics.append(result); continue
            }
            switch configuration.kind {
            case .twoBone: solveTwoBone(configuration, result: &result)
            case .fabrik: solveFABRIK(configuration, count: count, result: &result)
            }
            guard (0..<count).allSatisfy({ IKMath.finite(positions[$0]) }) else {
                result.status = .invalidPose; result.solverError = nil; diagnostics.append(result); continue
            }
            // Solve at full strength in parent space. Blend all local rotations only after reconstruction.
            for offset in 0..<(count - 1) {
                let index = entry.joints[offset], child = entry.joints[offset + 1]
                let parent = rig.nodes[index].parentIndex.map { globals[$0] } ?? .identity
                globals[index] = parent * poses[index].matrix
                let currentDirection = (globals[index] * poses[child].matrix).origin - globals[index].origin
                let desiredDirection = positions[offset + 1] - positions[offset]
                let inverse = parent.inverse
                let delta = IKMath.rotation(from: (inverse * Vector4(currentDirection, 0)).xyz,
                                            to: (inverse * Vector4(desiredDirection, 0)).xyz)
                poses[index].rotation = IKMath.multiply(delta, poses[index].rotation)
                globals[index] = parent * poses[index].matrix
            }
            for offset in 0..<(count - 1) {
                let index = entry.joints[offset]
                poses[index].rotation = slerpQuat(rotations[offset], poses[index].rotation, t: configuration.influence)
            }
            IKMath.rebuild(rig: rig, poses: poses, locals: &locals, globals: &globals)
            let reachError = IKMath.length(globals[entry.joints[count - 1]].origin - configuration.target)
            if reachError.isFinite, entry.joints.allSatisfy({ IKMath.supported(globals[$0]) }) { result.reachError = reachError }
            else {
                for offset in 0..<(count - 1) { poses[entry.joints[offset]].rotation = rotations[offset] }
                IKMath.rebuild(rig: rig, poses: poses, locals: &locals, globals: &globals)
                result.status = .invalidPose; result.solverError = nil
            }
            diagnostics.append(result)
        }
    }

    private mutating func solveTwoBone(_ configuration: AnimationPoseModifier, result: inout AnimationPoseModifierDiagnostic) {
        let root = positions[0]
        let target = configuration.target - root
        let distance = IKMath.length(target)
        let direction = IKMath.unit(target, fallback: IKMath.unit(positions[2] - root, fallback: IKMath.unit(positions[1] - root)))
        let a = Double(lengths[0]), b = Double(lengths[1])
        let reach = min(max(Double(distance), abs(a - b)), a + b)
        var bend = configuration.pole.map { $0 - root } ?? (positions[1] - root)
        bend = bend - direction * bend.dot(direction)
        if IKMath.length(bend) < 1e-7 {
            let base = positions[1] - root
            bend = base - direction * base.dot(direction)
        }
        bend = IKMath.unit(bend, fallback: IKMath.perpendicular(direction))
        let along = reach > 1e-12 ? (a * a - b * b + reach * reach) / (2 * reach) : 0
        let height = sqrt(max(0, a * a - along * along))
        positions[1] = root + direction * Float(along) + bend * Float(height)
        positions[2] = root + direction * Float(reach)
        result.iterations = 1
        result.solverError = IKMath.length(positions[2] - configuration.target)
        let tolerance = configuration.tolerance ?? max(1e-5, Float(a + b) * 1e-4)
        result.status = (result.solverError ?? 0) <= tolerance ? .solved : .unreachable
    }

    private mutating func solveFABRIK(_ configuration: AnimationPoseModifier, count: Int,
                                    result: inout AnimationPoseModifierDiagnostic) {
        let root = positions[0]
        var total: Float = 0
        var longest: Float = 0
        for index in 0..<(count - 1) { total += lengths[index]; longest = max(longest, lengths[index]) }
        guard total.isFinite else { positions[0] = Vector3(.infinity); return }
        let tolerance = configuration.tolerance ?? max(1e-5, total * 1e-4)
        let distance = IKMath.length(configuration.target - root)
        let direction = IKMath.unit(configuration.target - root, fallback: IKMath.unit(positions[count - 1] - root))
        if distance >= total {
            for index in 1..<count { positions[index] = positions[index - 1] + direction * lengths[index - 1] }
            result.solverError = IKMath.length(positions[count - 1] - configuration.target)
            result.status = (result.solverError ?? 0) <= tolerance ? .solved : .unreachable
            return
        }
        // Collinearity is a false fixed point for an interior target even when no vector is zero.
        var collinear = true
        var bend = Vector3.zero
        for index in 1..<count {
            let displacement = positions[index] - root
            let offAxis = displacement - direction * displacement.dot(direction)
            if IKMath.length(offAxis) > max(total * 1e-6, tolerance * 0.1) { collinear = false; bend = offAxis; break }
        }
        if collinear, count > 2 {
            bend = IKMath.unit(bend, fallback: IKMath.perpendicular(direction))
            let seed = max(total * 0.1, tolerance * 2)
            for index in 1..<(count - 1) {
                positions[index] += bend * (seed * sin(Float.pi * Float(index) / Float(count - 1)))
            }
        }
        var bestError = Float.infinity
        for iteration in 1...configuration.iterations {
            positions[count - 1] = configuration.target
            for index in stride(from: count - 2, through: 0, by: -1) {
                let backwards = IKMath.unit(positions[index] - positions[index + 1], fallback: -direction)
                positions[index] = positions[index + 1] + backwards * lengths[index]
            }
            positions[0] = root
            for index in 1..<count {
                let forwards = IKMath.unit(positions[index] - positions[index - 1], fallback: direction)
                positions[index] = positions[index - 1] + forwards * lengths[index - 1]
            }
            let error = IKMath.length(positions[count - 1] - configuration.target)
            result.iterations = iteration
            if error.isFinite, error < bestError {
                bestError = error
                for index in 0..<count { bestPositions[index] = positions[index] }
            }
            if bestError <= tolerance { break }
        }
        guard bestError.isFinite else { positions[0] = Vector3(.infinity); return }
        for index in 0..<count { positions[index] = bestPositions[index] }
        result.solverError = bestError
        if bestError <= tolerance { result.status = .solved }
        else { result.status = distance < max(0, longest - (total - longest)) ? .unreachable : .iterationLimit }
    }
}
