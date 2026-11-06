import AdaAnimation

/// A native `.animlib` resource, independent of its source GLB and playback instances.
public struct AnimationLibraryResource: Asset, Sendable {
    public let library: AnimationLibrary
    public var assetMetaInfo: AssetMetaInfo?

    public init(library: AnimationLibrary) throws {
        try library.validate()
        self.library = library
    }

    public init(from assetDecoder: any AssetDecoder) async throws {
        if assetDecoder.decoder != nil {
            try self.init(library: assetDecoder.decode(AnimationLibrary.self))
        } else {
            try self.init(library: AnimationLibrary.decode(assetDecoder.assetData))
        }
    }

    public func encodeContents(with assetEncoder: any AssetEncoder) async throws {
        try library.validate()
        if assetEncoder.encoder != nil {
            try assetEncoder.encode(library)
        } else {
            try assetEncoder.encode(library.encodedData())
        }
    }

    public static func extensions() -> [String] { ["animlib"] }
}
