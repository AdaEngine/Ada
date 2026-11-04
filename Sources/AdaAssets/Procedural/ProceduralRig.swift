/// Vertex influences for one mesh node. All four palette indices must be valid, including zero-weight entries.
public struct ProceduralSkinning: Sendable, Equatable {
    public var skin: Int
    public var joints: [SIMD4<UInt16>]
    public var weights: [SIMD4<Float>]

    public init(skin: Int, joints: [SIMD4<UInt16>], weights: [SIMD4<Float>]) {
        self.skin = skin
        self.joints = joints
        self.weights = weights
    }
}

/// A skin palette and its mesh-space inverse bind matrices, stored as column-major 4×4 values.
///
/// Each joint is a node index. The skeleton root must contain every joint in its subtree.
/// The writer follows the runtime profile of at most 128 joints and normalized four-component weights.
public struct ProceduralSkin: Sendable, Equatable {
    public var name: String
    public var skeletonRoot: Int
    public var joints: [Int]
    public var inverseBindMatrices: [SIMD16<Float>]

    public init(name: String, skeletonRoot: Int, joints: [Int], inverseBindMatrices: [SIMD16<Float>]) {
        self.name = name
        self.skeletonRoot = skeletonRoot
        self.joints = joints
        self.inverseBindMatrices = inverseBindMatrices
    }
}

/// A named, local-space TRS clip. Playback looping is configured by the model instance, not the GLB.
public struct ProceduralAnimation: Sendable, Equatable {
    public var name: String
    public var tracks: [Track]

    public init(name: String, tracks: [Track]) {
        self.name = name
        self.tracks = tracks
    }

    /// LINEAR quaternion tracks use shortest-path slerp in the native player. Values use xyz, or xyzw for rotations.
    public struct Track: Sendable, Equatable {
        public enum Path: String, Sendable { case translation, rotation, scale }
        public enum Interpolation: String, Sendable { case linear = "LINEAR", step = "STEP" }

        public var node: Int
        public var path: Path
        public var interpolation: Interpolation
        public var times: [Float]
        public var values: [SIMD4<Float>]

        public init(node: Int, path: Path, times: [Float], values: [SIMD4<Float>], interpolation: Interpolation = .linear) {
            self.node = node
            self.path = path
            self.times = times
            self.values = values
            self.interpolation = interpolation
        }
    }
}

extension ProceduralModel {
    func validateRig() throws {
        // Parent ordering is also checked here so skin ancestry walks cannot encounter a cycle.
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent, parent < 0 || parent >= index { throw GLBWritingError.invalidParent(node: index) }
        }
        for (index, skin) in skins.enumerated() {
            guard !skin.joints.isEmpty, skin.joints.count <= 128, Set(skin.joints).count == skin.joints.count,
                nodes.indices.contains(skin.skeletonRoot), skin.joints.allSatisfy({ nodes.indices.contains($0) }),
                skin.inverseBindMatrices.count == skin.joints.count,
                skin.inverseBindMatrices.allSatisfy({ matrix in
                    (0..<16).allSatisfy { matrix[$0].isFinite }
                        && matrix[3] == 0 && matrix[7] == 0 && matrix[11] == 0 && matrix[15] == 1
                })
            else { throw GLBWritingError.invalidSkin(index: index) }
            for joint in skin.joints {
                var ancestor: Int? = joint
                while let node = ancestor, node != skin.skeletonRoot { ancestor = nodes[node].parent }
                guard ancestor == skin.skeletonRoot else { throw GLBWritingError.invalidSkin(index: index) }
            }
        }
        for (index, node) in nodes.enumerated() {
            guard let binding = node.skinning else { continue }
            guard let mesh = node.mesh, skins.indices.contains(binding.skin), binding.joints.count == mesh.positions.count,
                binding.weights.count == mesh.positions.count,
                binding.joints.allSatisfy({ joints in (0..<4).allSatisfy { Int(joints[$0]) < skins[binding.skin].joints.count } }),
                binding.weights.allSatisfy({ weights in
                    (0..<4).allSatisfy { weights[$0].isFinite && weights[$0] >= 0 && weights[$0] <= 1 }
                        && abs(weights.sum() - 1) < 0.0001
                })
            else { throw GLBWritingError.invalidSkinning(node: index) }
        }
        for (index, animation) in animations.enumerated() {
            var targets: Set<String> = []
            guard !animation.name.isEmpty, !animation.tracks.isEmpty else { throw GLBWritingError.invalidAnimation(index: index) }
            for track in animation.tracks {
                guard nodes.indices.contains(track.node), targets.insert("\(track.node):\(track.path.rawValue)").inserted,
                    !track.times.isEmpty, track.times.count == track.values.count,
                    track.times.allSatisfy({ $0.isFinite && $0 >= 0 }), zip(track.times, track.times.dropFirst()).allSatisfy({ $0 < $1 }),
                    track.values.allSatisfy({ value in (0..<4).allSatisfy { value[$0].isFinite } }),
                    track.path != .rotation || track.values.allSatisfy({ abs(($0 * $0).sum() - 1) < 0.001 })
                else { throw GLBWritingError.invalidAnimation(index: index) }
            }
        }
    }
}
