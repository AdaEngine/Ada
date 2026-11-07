import Foundation
import Math

/// Portable, project-owned animation data. Imported model files remain unchanged.
/// Validate decoded or edited data before compiling it for playback.
public struct AnimationLibrary: Codable, Equatable, Sendable {
    public static let maximumEncodedBytes = 32 * 1024 * 1024
    /// Bounds the compiled scalar work/storage of native temporal curves in one library.
    public static let maximumCurveComponents = 500_000
    public var version: Int
    public var id: String
    public var binding: AnimationRigBinding
    public var clips: [AnimationLibraryClip]

    var requiresNativeCurveFormat: Bool {
        clips.contains { $0.tracks.contains { $0.interpolation == .bezier || $0.keys.contains { $0.curve != nil } } }
    }

    mutating func promoteNativeCurveFormat() {
        if version == 1, requiresNativeCurveFormat { version = 2 }
    }

    public init(id: String = UUID().uuidString, binding: AnimationRigBinding, clips: [AnimationLibraryClip] = [], version: Int = 1) {
        self.version = version
        self.id = id
        self.binding = binding
        self.clips = clips
    }

    /// Decodes portable data. Compilation also validates programmatically edited libraries.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else {
            throw AnimationAuthoringError(.limitExceeded, itemID: "library", message: "Animation libraries must be at most 32 MiB.")
        }
        let library = try JSONDecoder().decode(Self.self, from: data)
        try library.validate()
        return library
    }

    /// Encodes the same bounded JSON representation used by Studio and project resources.
    public func encodedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else {
            throw AnimationAuthoringError(.limitExceeded, itemID: id, message: "Animation libraries must be at most 32 MiB.")
        }
        return data
    }
}

/// A snapshot of the complete imported hierarchy, not offsets into a skin palette.
/// IDs belong to this binding. A changed source rig requires an explicit remap.
public struct AnimationRigBinding: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable {
        public var id: String
        public var name: String?
        public var parentID: String?
        public var restMatrix: Transform3D
        public var restTranslation: Vector3?
        public var restRotation: Vector4?
        public var restScale: Vector3?
        public var morphRestWeights: [Float]?

        public init(id: String, name: String? = nil, parentID: String? = nil, restMatrix: Transform3D = .identity,
                    restTranslation: Vector3? = nil, restRotation: Vector4? = nil, restScale: Vector3? = nil,
                    morphRestWeights: [Float]? = nil) {
            self.id = id
            self.name = name
            self.parentID = parentID
            self.restMatrix = restMatrix
            self.restTranslation = restTranslation
            self.restRotation = restRotation
            self.restScale = restScale
            self.morphRestWeights = morphRestWeights
        }
    }

    public var sourceAsset: String
    public var nodes: [Node]

    public init(sourceAsset: String, nodes: [Node]) {
        self.sourceAsset = sourceAsset
        self.nodes = nodes
    }
}

/// A reusable clip with an explicit timeline, including any hold after its final key.
public struct AnimationLibraryClip: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var duration: Double
    public var repeats: Bool
    public var sourceClip: String?
    public var sourceFingerprint: String?
    public var tracks: [AnimationLibraryTrack]

    public init(id: String = UUID().uuidString, name: String, duration: Double, repeats: Bool = true,
                sourceClip: String? = nil, sourceFingerprint: String? = nil, tracks: [AnimationLibraryTrack] = []) {
        self.id = id
        self.name = name
        self.duration = duration
        self.repeats = repeats
        self.sourceClip = sourceClip
        self.sourceFingerprint = sourceFingerprint
        self.tracks = tracks
    }
}

/// A typed bone TRS or mesh morph-weight track addressing a stable binding node ID.
public struct AnimationLibraryTrack: Codable, Equatable, Sendable {
    public enum Channel: String, CaseIterable, Codable, Sendable { case translation, rotation, scale, weights }
    public enum Interpolation: String, CaseIterable, Codable, Sendable { case linear, step, cubicSpline, bezier }

    public var id: String
    public var nodeID: String
    public var channel: Channel
    public var interpolation: Interpolation
    public var keys: [AnimationLibraryKey]

    public init(id: String = UUID().uuidString, nodeID: String, channel: Channel, interpolation: Interpolation = .linear,
                keys: [AnimationLibraryKey] = []) {
        self.id = id
        self.nodeID = nodeID
        self.channel = channel
        self.interpolation = interpolation
        self.keys = keys
    }
}

/// Cubic tangents are derivatives in value units per second, as in glTF CUBICSPLINE.
/// Rotations store XYZW quaternions; translation and scale store XYZ; weights use target order.
public struct AnimationLibraryKey: Codable, Equatable, Sendable {
    public var id: String
    public var time: Double
    public var value: [Float]
    public var incoming: [Float]?
    public var outgoing: [Float]?
    public var curve: AnimationKeyCurve?

    public init(id: String = UUID().uuidString, time: Double, value: [Float], incoming: [Float]? = nil, outgoing: [Float]? = nil, curve: AnimationKeyCurve? = nil) {
        self.id = id
        self.time = time
        self.value = value
        self.incoming = incoming
        self.outgoing = outgoing
        self.curve = curve
    }
}

/// A stable diagnostic code and the authored item that must be corrected.
public struct AnimationAuthoringError: Error, Equatable, LocalizedError, Sendable {
    public enum Code: String, Codable, Sendable {
        case unsupportedVersion, invalidIdentity, duplicateIdentity, invalidHierarchy, incompatibleRig, invalidCurve
        case invalidDuration, invalidTrack, invalidKey, missingTarget, missingClip, missingTrack, missingKey, conflict, limitExceeded
    }

    public let code: Code
    public let itemID: String
    public let message: String
    public var errorDescription: String? { message }

    public init(_ code: Code, itemID: String, message: String) {
        self.code = code
        self.itemID = itemID
        self.message = message
    }
}
