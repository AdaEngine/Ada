import Foundation

/// Portable `.animmod` data. Scene target bindings belong to a model instance, not this resource.
public struct AnimationModifierStack: Codable, Equatable, Sendable {
    public static let maximumEncodedBytes = 1_048_576
    public var version: Int
    public var id: String
    public var binding: AnimationRigBinding
    public var modifiers: [AnimationPoseModifier]

    public init(id: String = UUID().uuidString, binding: AnimationRigBinding, modifiers: [AnimationPoseModifier] = [], version: Int = 1) {
        self.version = version
        self.id = id
        self.binding = binding
        self.modifiers = modifiers
    }

    /// Validates before any playback or resource replacement. Unknown versions are never rewritten.
    public func validate() throws {
        guard version == 1, !id.isEmpty, id.utf8.count <= 256 else { throw AnimationPoseModifierError.invalidModifier(id) }
        let rig = try binding.makeRig()
        _ = try CompiledPoseModifiers(modifiers, rig: rig, binding: binding)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw AnimationPoseModifierError.limitExceeded }
        let stack = try JSONDecoder().decode(Self.self, from: data)
        try stack.validate()
        return stack
    }

    public func encodedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw AnimationPoseModifierError.limitExceeded }
        return data
    }
}
