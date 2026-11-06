import Foundation
import Math

/// An ordered, model-space constraint. Joint IDs belong to the complete rig binding.
public struct AnimationPoseModifier: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case twoBone, fabrik }
    public var id: String
    public var name: String?
    public var kind: Kind
    public var joints: [String]
    public var target: Vector3
    public var pole: Vector3?
    public var enabled: Bool
    public var influence: Float
    public var iterations: Int
    public var tolerance: Float?

    public init(id: String = UUID().uuidString, kind: Kind, joints: [String], target: Vector3,
                pole: Vector3? = nil, enabled: Bool = true, influence: Float = 1,
                iterations: Int = 16, tolerance: Float? = nil, name: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.joints = joints
        self.target = target
        self.pole = pole
        self.enabled = enabled
        self.influence = influence
        self.iterations = iterations
        self.tolerance = tolerance
    }
}

public enum AnimationPoseModifierError: Error, Equatable, Sendable {
    case incompatibleRig
    case invalidModifier(String)
    case invalidChain(String)
    case limitExceeded
}

extension AnimationPoseModifierError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .incompatibleRig: "IK binding does not match the complete model rig. Remap its stable bone IDs explicitly."
        case let .invalidModifier(id): "Invalid IK settings for '\(id)'. Check finite points, influence, tolerance and unique IDs."
        case let .invalidChain(id): "Invalid IK chain for '\(id)'. Choose directly parented, editable joints with nonzero segments."
        case .limitExceeded: "IK limits exceeded: 32 modifiers, 64 segments, 1–64 iterations and 32,768 segment-iterations per stack."
        }
    }
}

/// Ephemeral input resolved from one current scene snapshot, never persisted into a reusable stack.
/// A nil target explicitly means that a bound scene target is unavailable.
public struct AnimationPoseModifierInput: Sendable {
    public var target: Vector3?
    public var pole: Vector3?
    public var supportsTransform: Bool

    public init(target: Vector3?, pole: Vector3? = nil, supportsTransform: Bool = true) {
        self.target = target
        self.pole = pole
        self.supportsTransform = supportsTransform
    }
}

/// A bounded result for one modifier. Errors are measured in model-space units.
public struct AnimationPoseModifierDiagnostic: Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case solved, unreachable, iterationLimit, disabled, invalidTarget, unsupportedTransform, invalidPose
    }
    public var id: String
    public var status: Status
    public var iterations: Int
    /// Distance after the full-strength solve, before influence blending.
    public var solverError: Float?
    /// Distance from the endpoint actually published after influence blending.
    public var reachError: Float?
}
