import Foundation
import Math

/// Motion in the standard SOMA T-pose basis, with global XYZW rotations and meter-space pelvis positions.
public struct SOMAHumanoidMotion: Decodable, Sendable {
    public let protocolVersion: Int
    public let jobID: UUID
    public let framesPerSecond: Double
    public let jointNames: [String]
    public let referenceHeight: Float
    public let rootPositions: [[Float]]
    public let globalRotations: [[[Float]]]

    public enum Failure: LocalizedError, Equatable, Sendable {
        case invalidMotion
        case unsupportedJoint(String)

        public var errorDescription: String? {
            switch self {
            case .invalidMotion: "The generated SOMA motion is invalid."
            case .unsupportedJoint(let name): "The selected humanoid has a missing or unsupported joint: \(name)."
            }
        }
    }

    /// Transfers a generated clip to the Ada humanoid reference hierarchy.
    public func clip(named name: String, for rig: SkeletalRig) throws -> SkeletalAnimationClip {
        let targets = try Self.targetIndices(rig)
        let count = rootPositions.count
        let sourceIndices = try Self.profile.map { entry in
            try Self.uniqueIndex(named: entry.source, in: jointNames.map(Optional.some), failure: .invalidMotion)
        }
        guard protocolVersion == 1, count > 0, count <= 300, count == globalRotations.count,
              framesPerSecond == 30, referenceHeight.isFinite, referenceHeight > 0.01,
              (1...77).contains(jointNames.count), Set(jointNames).count == jointNames.count,
              globalRotations.allSatisfy({ $0.count == jointNames.count }) else { throw Failure.invalidMotion }

        let rest = Self.restTransforms(rig)
        let root = targets[0]
        let hipsParent = rig.nodes[root].parentIndex.map { rest[$0] } ?? .identity
        let hipsHeight = rest[root].origin.y - hipsParent.origin.y
        guard hipsHeight.isFinite, hipsHeight > 0.01, let hips = rig.nodes[root].restPose else { throw Failure.unsupportedJoint("Root") }
        let factor = hipsHeight / referenceHeight
        let initialPosition = try Self.vector(rootPositions[0])
        let inverse = hipsParent.inverse
        let times = (0..<count).map { Double($0) / framesPerSecond }
        let rootValues = try rootPositions.map { row in
            let delta = (try Self.vector(row) - initialPosition) * factor
            let local = inverse.x.xyz * delta.x + inverse.y.xyz * delta.y + inverse.z.xyz * delta.z
            let value = hips.translation + local
            return Vector4(value.x, value.y, value.z, 0)
        }
        var tracks = [try SkeletalAnimationTrack(nodeIndex: root, path: .translation, interpolation: .linear, times: times, values: rootValues)]
        let restRotations = targets.map { rest[$0].rotation.normalized }
        for entryIndex in Self.profile.indices {
            let parent = Self.profile[entryIndex].parent
            let values = try globalRotations.map { frame in
                let generated = try Self.rotation(frame[sourceIndices[entryIndex]])
                let world = IKMath.multiply(generated, restRotations[entryIndex])
                let parentWorld = try parent.map { parentIndex in
                    try IKMath.multiply(Self.rotation(frame[sourceIndices[parentIndex]]), restRotations[parentIndex])
                } ?? hipsParent.rotation.normalized
                let inverseParent = Quat(x: -parentWorld.x, y: -parentWorld.y, z: -parentWorld.z, w: parentWorld.w)
                let local = IKMath.multiply(inverseParent, world)
                return Vector4(local.x, local.y, local.z, local.w)
            }
            tracks.append(try .init(nodeIndex: targets[entryIndex], path: .rotation, interpolation: .linear, times: times, values: values))
        }
        return try SkeletalAnimationClip(name: name, tracks: tracks, duration: Double(count) / framesPerSecond)
    }

    /// Checks the required named joints, direct hierarchy, and transform basis before starting a generation job.
    public static func validateTarget(_ rig: SkeletalRig) throws {
        _ = try targetIndices(rig)
    }

    private static func targetIndices(_ rig: SkeletalRig) throws -> [Int] {
        let names = rig.nodes.map(\.name)
        let indices = try profile.map { try uniqueIndex(named: $0.target, in: names, failure: .unsupportedJoint($0.target)) }
        let matrices = restTransforms(rig)
        for (entry, index) in zip(profile, indices) {
            let node = rig.nodes[index]
            let parent = entry.parent.map { indices[$0] }
            guard node.restPose != nil, IKMath.supported(matrices[index]),
                  (parent == nil || node.parentIndex == parent) else { throw Failure.unsupportedJoint(entry.target) }
        }
        return indices
    }

    private static func restTransforms(_ rig: SkeletalRig) -> [Transform3D] {
        var result = Array(repeating: Transform3D.identity, count: rig.nodes.count)
        for index in rig.evaluationOrder {
            let node = rig.nodes[index]
            let local = node.restPose?.matrix ?? node.restMatrix
            result[index] = node.parentIndex.map { result[$0] * local } ?? local
        }
        return result
    }

    private static func uniqueIndex(named name: String, in names: [String?], failure: Failure) throws -> Int {
        guard let first = names.firstIndex(of: name), first == names.lastIndex(of: name) else { throw failure }
        return first
    }

    private static func rotation(_ values: [Float]) throws -> Quat {
        guard values.count == 4 else { throw Failure.invalidMotion }
        let rotation = Quat(x: values[0], y: values[1], z: values[2], w: values[3])
        guard abs(rotation.squaredLength - 1) < 0.01 else { throw Failure.invalidMotion }
        return rotation.normalized
    }

    private static func vector(_ values: [Float]) throws -> Vector3 {
        guard values.count == 3, values.allSatisfy(\.isFinite) else { throw Failure.invalidMotion }
        return Vector3(values[0], values[1], values[2])
    }

    private static let profile: [(source: String, target: String, parent: Int?)] = [
        ("Hips", "Root", nil), ("Chest", "Spine", 0), ("Head", "Head", 1),
        ("LeftArm", "ArmL", 1), ("LeftForeArm", "ForeArmL", 3),
        ("RightArm", "ArmR", 1), ("RightForeArm", "ForeArmR", 5),
        ("LeftLeg", "LegL", 0), ("LeftShin", "LowerLegL", 7),
        ("RightLeg", "LegR", 0), ("RightShin", "LowerLegR", 9)
    ]
}
