import AdaAssets
import Math

/// A deliberately authored rig for this character's proportions, in its original bind pose.
enum Joint: Int, CaseIterable {
    case root, hips, spine, chest, neck, head, jaw
    case leftHip, leftKnee, leftAnkle, leftToe
    case rightHip, rightKnee, rightAnkle, rightToe
    case leftShoulder, leftElbow, leftWrist, leftHand
    case rightShoulder, rightElbow, rightWrist, rightHand

    var node: Int { rawValue + 1 }
    var name: String { "Rig." + String(describing: self) }

    var parent: Joint? {
        switch self {
        case .root: nil
        case .hips: .root
        case .spine, .leftHip, .rightHip: .hips
        case .chest: .spine
        case .neck, .leftShoulder, .rightShoulder: .chest
        case .head: .neck
        case .jaw: .head
        case .leftKnee: .leftHip
        case .leftAnkle: .leftKnee
        case .leftToe: .leftAnkle
        case .rightKnee: .rightHip
        case .rightAnkle: .rightKnee
        case .rightToe: .rightAnkle
        case .leftElbow: .leftShoulder
        case .leftWrist: .leftElbow
        case .leftHand: .leftWrist
        case .rightElbow: .rightShoulder
        case .rightWrist: .rightElbow
        case .rightHand: .rightWrist
        }
    }

    var position: Vector3 {
        switch self {
        case .root: [0, 0, 0]
        case .hips: [0, 0.39, 0]
        case .spine: [0, 0.68, 0]
        case .chest: [0, 0.9, 0]
        case .neck: [0, 1.005, 0]
        case .head: [0, 1.14, 0]
        case .jaw: [0, 0.99, -0.1]
        case .leftHip: [-0.14, 0.34, 0]
        case .leftKnee: [-0.14, 0.26, 0]
        case .leftAnkle: [-0.14, 0.12, -0.015]
        case .leftToe: [-0.14, 0.05, -0.16]
        case .rightHip: [0.14, 0.34, 0]
        case .rightKnee: [0.14, 0.26, 0]
        case .rightAnkle: [0.14, 0.12, -0.015]
        case .rightToe: [0.14, 0.05, -0.16]
        case .leftShoulder: [-0.31, 0.91, 0]
        case .leftElbow: [-0.49, 0.86, -0.012]
        case .leftWrist: [-0.66, 0.86, -0.045]
        case .leftHand: [-0.7, 0.86, -0.045]
        case .rightShoulder: [0.31, 0.91, 0]
        case .rightElbow: [0.49, 0.86, -0.012]
        case .rightWrist: [0.66, 0.86, -0.045]
        case .rightHand: [0.7, 0.86, -0.045]
        }
    }

    var local: Vector3 { position - (parent?.position ?? .zero) }
}

struct SkeletonRig {
    static var nodes: [ProceduralNode] {
        [ProceduralNode(name: "Skeleton skinned")] + Joint.allCases.map { joint in
            var node = ProceduralNode(name: joint.name)
            node.parent = joint.parent?.node ?? 0
            node.translation = joint.local.simd
            return node
        }
    }

    static var skin: ProceduralSkin {
        ProceduralSkin(name: "Skeleton humanoid", skeletonRoot: Joint.root.node,
                       joints: Joint.allCases.map(\.node), inverseBindMatrices: Joint.allCases.map { joint in
            let p = joint.position
            return SIMD16(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -p.x, -p.y, -p.z, 1)
        })
    }
}

extension Vector3 {
    var simd: SIMD3<Float> { SIMD3(x, y, z) }
}
