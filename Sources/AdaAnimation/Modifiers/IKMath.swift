import Math

/// Numerical helpers use explicit parent frames, never an assumed imported bone axis.
enum IKMath {
    static func finite(_ value: Vector3) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }

    static func length(_ value: Vector3) -> Float {
        Float(sqrt(Double(value.x) * Double(value.x) + Double(value.y) * Double(value.y) + Double(value.z) * Double(value.z)))
    }

    static func unit(_ value: Vector3, fallback: Vector3 = [1, 0, 0]) -> Vector3 {
        let magnitude = length(value)
        return magnitude.isFinite && magnitude > 1e-12 ? value / magnitude : fallback
    }

    /// Stable axis choice, with X/Y/Z tie ordering.
    static func perpendicular(_ direction: Vector3) -> Vector3 {
        let axis: Vector3
        if abs(direction.x) <= abs(direction.y), abs(direction.x) <= abs(direction.z) { axis = [1, 0, 0] }
        else if abs(direction.y) <= abs(direction.z) { axis = [0, 1, 0] }
        else { axis = [0, 0, 1] }
        return unit(axis - direction * axis.dot(direction))
    }

    static func multiply(_ lhs: Quat, _ rhs: Quat) -> Quat {
        Quat(x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
             y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
             z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w,
             w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z).normalized
    }

    static func rotation(from: Vector3, to: Vector3) -> Quat {
        let from = unit(from)
        let to = unit(to)
        let dot = min(max(from.dot(to), -1), 1)
        let cross = from.cross(to)
        let crossLength = length(cross)
        if crossLength > 0 {
            // atan2 retains small deviations around pi even when Float dot has rounded to -1.
            return Quat(axis: cross / crossLength, angle: atan2(crossLength, dot))
        }
        return dot < 0 ? Quat(axis: perpendicular(from), angle: .pi) : .identity
    }

    static func supported(_ matrix: Transform3D) -> Bool {
        let x = matrix.x.xyz, y = matrix.y.xyz, z = matrix.z.xyz
        guard finite(matrix.origin), finite(x), finite(y), finite(z) else { return false }
        let scale = length(x)
        guard scale.isFinite, scale > 1e-8 else { return false }
        let nx = x / scale, ny = y / scale, nz = z / scale
        return abs(length(ny) - 1) < 0.0001 && abs(length(nz) - 1) < 0.0001
            && abs(nx.dot(ny)) < 0.0001 && abs(nx.dot(nz)) < 0.0001 && abs(ny.dot(nz)) < 0.0001
            && nx.cross(ny).dot(nz) > 0.9999
    }

    static func rebuild(rig: SkeletalRig, poses: [SkeletalJointPose], locals: inout [Transform3D], globals: inout [Transform3D]) {
        for index in rig.evaluationOrder {
            let node = rig.nodes[index]
            locals[index] = node.restPose == nil ? node.restMatrix : poses[index].matrix
            globals[index] = node.parentIndex.map { globals[$0] * locals[index] } ?? locals[index]
        }
    }
}
