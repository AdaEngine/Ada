import Foundation
import Math

/// A portable, acyclic pose graph. IDs are stable across edits and scene serialization.
/// Blend nodes normalize weights above one and fill remaining weight with the rest pose.
/// Additive nodes use their first input as the base, then apply rest-relative local deltas.
public struct AnimationGraph: Codable, Equatable, Sendable {
    public var root: String
    public var nodes: [Node]

    public init(root: String, nodes: [Node]) {
        self.root = root
        self.nodes = nodes
    }

    public struct Node: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable { case clip, blend, additive }
        public var id: String
        public var kind: Kind
        public var clip: String
        public var speed: Double
        public var repeats: Bool
        public var inputs: [Input]
        public var events: [Marker]

        public init(id: String, kind: Kind = .clip, clip: String = "", speed: Double = 1, repeats: Bool = true, inputs: [Input] = [], events: [Marker] = []) {
            self.id = id
            self.kind = kind
            self.clip = clip
            self.speed = speed
            self.repeats = repeats
            self.inputs = inputs
            self.events = events
        }
    }

    public struct Input: Codable, Equatable, Sendable {
        public var node: String
        public var weight: Float
        public var mask: Mask?

        public init(node: String, weight: Float = 1, mask: Mask? = nil) {
            self.node = node
            self.weight = weight
            self.mask = mask
        }
    }

    /// Each joint entry overrides the default, optionally for its whole subtree.
    /// Entries are applied in order, allowing a subtree to exclude individual descendants.
    public struct Mask: Codable, Equatable, Sendable {
        public var defaultWeight: Float
        public var joints: [Joint]

        public init(defaultWeight: Float = 0, joints: [Joint] = []) {
            self.defaultWeight = defaultWeight
            self.joints = joints
        }

        public struct Joint: Codable, Equatable, Sendable {
            public var nodeIndex: Int
            public var weight: Float
            public var includesDescendants: Bool

            public init(nodeIndex: Int, weight: Float = 1, includesDescendants: Bool = true) {
                self.nodeIndex = nodeIndex
                self.weight = weight
                self.includesDescendants = includesDescendants
            }
        }
    }

    /// A named gameplay marker in clip-local seconds. Payload is application-defined text.
    public struct Marker: Codable, Equatable, Sendable {
        public var time: Double
        public var name: String
        public var payload: String

        public init(time: Double, name: String, payload: String = "") {
            self.time = time
            self.name = name
            self.payload = payload
        }
    }

    /// Validates references, cycles, clips, masks and event times against a model.
    public func validate(rig: SkeletalRig, clips: [SkeletalAnimationClip]) throws(AnimationGraphError) {
        _ = try CompiledAnimationGraph(graph: self, rig: rig, clips: clips)
    }
}

public enum AnimationGraphError: Error, Equatable, LocalizedError, Sendable {
    case invalidNode(String)
    case missingNode(String)
    case cycle(String)
    case missingClip(String)
    case invalidWeight
    case invalidMask(Int)
    case invalidEvent(String)

    public var errorDescription: String? {
        switch self {
        case .invalidNode(let node): "Node '\(node)' has invalid inputs or playback settings."
        case .missingNode(let node): "Connect or add the missing node '\(node)'."
        case .cycle(let node): "A connection through '\(node)' creates a cycle."
        case .missingClip(let clip): "This model has no clip named '\(clip)'."
        case .invalidWeight: "Blend weights must be in 0...1000; bone mask weights must be in 0...1."
        case .invalidMask(let node): "The mask references missing model node \(node)."
        case .invalidEvent(let name): "Event '\(name)' needs a name and a time within its clip."
        }
    }
}

/// One crossing of a clip marker, including its contribution to the active graph.
public struct AnimationGraphEvent: Equatable, Sendable {
    public let node: String
    public let clip: String
    public let marker: AnimationGraph.Marker
    public let weight: Float
    public let graphTime: Double
}
