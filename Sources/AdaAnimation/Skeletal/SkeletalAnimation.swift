import Foundation
import Math

/// A local joint transform. Quaternion rotations remain separate from scale.
public struct SkeletalJointPose: Sendable, Equatable {
    public var translation: Vector3
    public var rotation: Quat
    public var scale: Vector3

    public init(translation: Vector3 = .zero, rotation: Quat = .identity, scale: Vector3 = .one) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    public var matrix: Transform3D {
        Transform3D(translation: translation, rotation: rotation, scale: scale)
    }
}

public enum SkeletalAnimationError: Error, Equatable, Sendable {
    case invalidHierarchy
    case invalidTrack
    case unknownClip(String)
}

/// The entire model hierarchy, including non-joint nodes and matrix-authored nodes.
public struct SkeletalRig: Sendable {
    public struct Node: Sendable {
        public let parentIndex: Int?
        public let restPose: SkeletalJointPose?
        public let restMatrix: Transform3D

        public init(parentIndex: Int?, restPose: SkeletalJointPose?, restMatrix: Transform3D) {
            self.parentIndex = parentIndex
            self.restPose = restPose
            self.restMatrix = restMatrix
        }
    }

    public let nodes: [Node]
    public let evaluationOrder: [Int]

    public init(nodes: [Node]) throws(SkeletalAnimationError) {
        var children = [[Int]](repeating: [], count: nodes.count)
        var pending: [Int] = []
        for (index, node) in nodes.enumerated() {
            if let parent = node.parentIndex {
                guard nodes.indices.contains(parent), parent != index else { throw .invalidHierarchy }
                children[parent].append(index)
            } else {
                pending.append(index)
            }
        }
        var order: [Int] = []
        order.reserveCapacity(nodes.count)
        while let index = pending.popLast() {
            order.append(index)
            pending.append(contentsOf: children[index])
        }
        guard order.count == nodes.count else { throw .invalidHierarchy }
        self.nodes = nodes
        self.evaluationOrder = order
    }
}

/// A validated glTF-style TRS track. Cubic keys retain in/value/out triples.
public struct SkeletalAnimationTrack: Sendable {
    public enum Path: String, Sendable { case translation, rotation, scale }
    public enum Interpolation: String, Sendable { case linear, step, cubicSpline }

    public let nodeIndex: Int
    public let path: Path
    public let interpolation: Interpolation
    public let times: [Double]
    public let values: [Vector4]

    public init(
        nodeIndex: Int,
        path: Path,
        interpolation: Interpolation,
        times: [Double],
        values: [Vector4]
    ) throws(SkeletalAnimationError) {
        let multiplier = interpolation == .cubicSpline ? 3 : 1
        guard nodeIndex >= 0, !times.isEmpty, times.allSatisfy({ $0.isFinite && $0 >= 0 }),
            zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }),
            values.count / multiplier == times.count, values.count.isMultiple(of: multiplier),
            values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
        else { throw .invalidTrack }
        if path == .rotation {
            for index in times.indices {
                let value = values[index * multiplier + (multiplier == 3 ? 1 : 0)]
                guard abs(value.dot(value) - 1) < 0.001 else { throw .invalidTrack }
            }
        }
        self.nodeIndex = nodeIndex
        self.path = path
        self.interpolation = interpolation
        self.times = times
        self.values = values
    }

    /// Samples without sorting or allocating. Quaternion LINEAR uses shortest-path slerp.
    public func sample(at time: Double) -> Vector4 {
        guard time.isFinite, time > times[0] else {
            return value(at: 0)
        }
        guard time < times[times.count - 1] else {
            return value(at: times.count - 1)
        }
        var lower = 0
        var upper = times.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if times[middle] <= time { lower = middle } else { upper = middle }
        }
        let start = value(at: lower)
        if interpolation == .step {
            return start
        }
        let end = value(at: upper)
        let span = Float(times[upper] - times[lower])
        let amount = Float((time - times[lower]) / (times[upper] - times[lower]))
        if interpolation == .linear {
            if path == .rotation {
                return vector(slerpQuat(quaternion(start), quaternion(end), t: amount))
            }
            return start + (end - start) * amount
        }
        let squared = amount * amount
        let cubed = squared * amount
        let outgoing = values[lower * 3 + 2] * span
        let incoming = values[upper * 3] * span
        let result = start * (2 * cubed - 3 * squared + 1)
            + outgoing * (cubed - 2 * squared + amount)
            + end * (-2 * cubed + 3 * squared)
            + incoming * (cubed - squared)
        if path == .rotation {
            let lengthSquared = result.dot(result)
            return lengthSquared > 0.000001 ? result / sqrt(lengthSquared) : start
        }
        return result
    }

    private func value(at index: Int) -> Vector4 {
        values[index * (interpolation == .cubicSpline ? 3 : 1) + (interpolation == .cubicSpline ? 1 : 0)]
    }

    private func quaternion(_ value: Vector4) -> Quat {
        Quat(x: value.x, y: value.y, z: value.z, w: value.w)
    }

    private func vector(_ value: Quat) -> Vector4 {
        Vector4(value.x, value.y, value.z, value.w)
    }
}

public struct SkeletalAnimationClip: Sendable {
    public let name: String
    public let tracks: [SkeletalAnimationTrack]
    public let duration: Double

    public init(name: String, tracks: [SkeletalAnimationTrack]) {
        self.name = name
        self.tracks = tracks
        self.duration = tracks.compactMap { $0.times.last }.max() ?? 0
    }
}
