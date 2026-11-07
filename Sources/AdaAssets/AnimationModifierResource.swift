import AdaAnimation

/// An independently saved native `.animmod` resource with complete rig compatibility.
public struct AnimationModifierResource: Asset, Sendable {
    public let stack: AnimationModifierStack
    public var assetMetaInfo: AssetMetaInfo?

    public init(stack: AnimationModifierStack) throws {
        try stack.validate()
        self.stack = stack
    }

    public init(from assetDecoder: any AssetDecoder) async throws {
        if assetDecoder.decoder != nil { try self.init(stack: assetDecoder.decode(AnimationModifierStack.self)) }
        else { try self.init(stack: AnimationModifierStack.decode(assetDecoder.assetData)) }
    }

    public func encodeContents(with assetEncoder: any AssetEncoder) async throws {
        try stack.validate()
        if assetEncoder.encoder != nil { try assetEncoder.encode(stack) }
        else { try assetEncoder.encode(stack.encodedData()) }
    }

    public static func extensions() -> [String] { ["animmod"] }
}
