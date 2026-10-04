import Math

extension GLTFImportResult {
    /// Local bind/rest transform, retained without matrix decomposition.
    public struct NodeTRS: Sendable {
        public let translation: Vector3
        public let rotation: Quat
        public let scale: Vector3

        public init(translation: Vector3 = .zero, rotation: Quat = .identity, scale: Vector3 = .one) {
            self.translation = translation
            self.rotation = rotation
            self.scale = scale
        }

        public var matrix: Transform3D {
            Transform3D(translation: translation, rotation: rotation, scale: scale)
        }
    }

    /// Joint indices address this skin's ordered joints array, not the node array.
    public struct Skin: Sendable {
        public let name: String?
        public let joints: [Int]
        public let skeletonRootIndex: Int?
        public let inverseBindMatrices: [Transform3D]

        public init(name: String?, joints: [Int], skeletonRootIndex: Int?, inverseBindMatrices: [Transform3D]) {
            self.name = name
            self.joints = joints
            self.skeletonRootIndex = skeletonRootIndex
            self.inverseBindMatrices = inverseBindMatrices
        }
    }

    /// Four influences per vertex. Weights are normalized during native import.
    public struct Skinning: Sendable {
        public let jointIndices: [SIMD4<UInt16>]
        public let weights: [Vector4]

        public init(jointIndices: [SIMD4<UInt16>], weights: [Vector4]) {
            self.jointIndices = jointIndices
            self.weights = weights
        }
    }

    public enum AnimationInterpolation: String, Sendable {
        case linear = "LINEAR"
        case step = "STEP"
        case cubicSpline = "CUBICSPLINE"
    }

    public enum AnimationPath: String, Sendable {
        case translation
        case rotation
        case scale
    }

    public struct AnimationSampler: Sendable {
        /// Strictly increasing timestamps in seconds.
        public let times: [Float]
        /// For cubic splines each key stores in-tangent, value, out-tangent, in that order.
        public let output: Accessor
        public let interpolation: AnimationInterpolation

        public init(times: [Float], output: Accessor, interpolation: AnimationInterpolation) {
            self.times = times
            self.output = output
            self.interpolation = interpolation
        }
    }

    public struct AnimationChannel: Sendable {
        public let samplerIndex: Int
        public let nodeIndex: Int
        public let path: AnimationPath

        public init(samplerIndex: Int, nodeIndex: Int, path: AnimationPath) {
            self.samplerIndex = samplerIndex
            self.nodeIndex = nodeIndex
            self.path = path
        }
    }

    /// An imported clip; playback and pose evaluation belong to the animation runtime.
    public struct Animation: Sendable {
        public let name: String?
        public let samplers: [AnimationSampler]
        public let channels: [AnimationChannel]

        public var duration: Float {
            samplers.compactMap { $0.times.last }.max() ?? 0
        }

        public init(name: String?, samplers: [AnimationSampler], channels: [AnimationChannel]) {
            self.name = name
            self.samplers = samplers
            self.channels = channels
        }
    }
}
