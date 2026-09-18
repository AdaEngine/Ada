//
//  NamedTextureAtlas.swift
//  AdaEngine
//

import AdaAssets
import Foundation
import Math
import Synchronization

/// Texture atlas keyed by string names (for packed UI assets). Distinct from grid-based ``TextureAtlas``.
public final class NamedTextureAtlas: Asset, @unchecked Sendable {
    public private(set) var texture: Texture2D

    public private(set) var entriesByKey: [String: AtlasRegion]

    public var assetMetaInfo: AssetMetaInfo?

    /// The source descriptor when this atlas was loaded from an `.atlas` resource.
    public private(set) var descriptor: Descriptor?

    private let sliceCache = Mutex([String: Slice]())

    public init(
        texture: Texture2D,
        entriesByKey: [String: AtlasRegion],
        descriptor: Descriptor? = nil,
        assetMetaInfo: AssetMetaInfo? = nil
    ) {
        self.texture = texture
        self.entriesByKey = entriesByKey
        self.descriptor = descriptor
        self.assetMetaInfo = assetMetaInfo
    }

    public subscript(_ key: String) -> Texture2D? {
        slice(for: key)
    }

    public func slice(for key: String) -> Texture2D? {
        sliceCache.withLock { cache in
            if let cached = cache[key] {
                return cached
            }
            guard let region = entriesByKey[key] else {
                return nil
            }
            let piece = Slice(namedAtlas: self, region: region)
            cache[key] = piece
            return piece
        }
    }

    /// Returns the metadata for a named image without creating a texture slice.
    public func region(for key: String) -> AtlasRegion? {
        entriesByKey[key]
    }

    public func contains(_ key: String) -> Bool {
        entriesByKey[key] != nil
    }

    public var keys: [String] {
        entriesByKey.keys.sorted()
    }

    /// Builds a CPU ``Image`` for the logical sprite pixels (same dimensions as the original PNG).
    public func image(for key: String, atlasRGBA: Data, atlasWidth: Int, atlasHeight _: Int) -> Image? {
        guard let region = entriesByKey[key] else {
            return nil
        }
        let w = region.originalSize.width
        let h = region.originalSize.height
        guard w > 0, h > 0 else {
            return nil
        }
        var out = Data(count: w * h * 4)
        let srcStride = atlasWidth * 4
        let ox = region.contentOriginInAtlas.x
        let oy = region.contentOriginInAtlas.y
        for row in 0..<h {
            let srcStart = (oy + row) * srcStride + ox * 4
            let dstStart = row * w * 4
            out.replaceSubrange(
                dstStart..<dstStart + w * 4,
                with: atlasRGBA.subdata(in: srcStart..<srcStart + w * 4)
            )
        }
        return Image(width: w, height: h, data: out, format: .rgba8)
    }

    public required init(from assetDecoder: any AssetDecoder) async throws {
        guard Self.extensions().contains(assetDecoder.assetMeta.filePath.pathExtension.lowercased()) else {
            throw AssetDecodingError.invalidAssetExtension(assetDecoder.assetMeta.filePath.pathExtension)
        }

        let descriptor = try assetDecoder.decode(Descriptor.self)
        let baseURL = assetDecoder.assetMeta.filePath.deletingLastPathComponent()
        var inputs: [NamedTextureAtlasPacker.Input] = []
        inputs.reserveCapacity(descriptor.images.count)

        for source in descriptor.images {
            let resolvedPath = Self.resolve(source.path, relativeTo: baseURL)
            let imageHandle = try await AssetsManager.load(Image.self, at: resolvedPath)
            guard let image = imageHandle.asset else {
                throw AssetDecodingError.decodingProblem("NamedTextureAtlas: image at \(source.path) was not loaded.")
            }
            let key = source.key ?? Self.defaultKey(for: source.path)
            inputs.append(NamedTextureAtlasPacker.Input(key: key, image: image))
        }

        let result = try NamedTextureAtlasPacker.pack(inputs, descriptor: descriptor)
        self.texture = Texture2D(image: result.image, samplerDescription: descriptor.filter.samplerDescriptor)
        self.entriesByKey = result.entriesByKey
        self.descriptor = descriptor
    }

    public func encodeContents(with assetEncoder: any AssetEncoder) async throws {
        guard let descriptor else {
            throw AssetDecodingError.decodingProblem("NamedTextureAtlas: only atlases created from a descriptor can be encoded.")
        }
        try assetEncoder.encode(descriptor)
    }

    public static func extensions() -> [String] {
        ["atlas"]
    }

    private static func resolve(_ path: String, relativeTo baseURL: URL) -> String {
        if path.hasPrefix("@res://") || path.hasPrefix("file://") || isAbsolutePath(path) {
            return path
        }
        return baseURL.appendingPathComponent(path, isDirectory: false).standardizedFileURL.path
    }

    private static func isAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("\\\\") {
            return true
        }
        let prefix = Array(path.prefix(3))
        return prefix.count == 3
            && prefix[0].isLetter
            && prefix[1] == ":"
            && (prefix[2] == "/" || prefix[2] == "\\")
    }

    private static func defaultKey(for path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).deletingPathExtension().lastPathComponent
    }
}

// MARK: - Slice

extension NamedTextureAtlas {
    /// A ``Texture2D`` view into one named region of the atlas.
    public final class Slice: Texture2D, @unchecked Sendable {
        public private(set) var namedAtlas: NamedTextureAtlas

        private let uvMin: Vector2
        private let uvMax: Vector2

        public let position: Vector2

        init(namedAtlas: NamedTextureAtlas, region: AtlasRegion) {
            self.namedAtlas = namedAtlas
            self.uvMin = region.uvMin
            self.uvMax = region.uvMax
            self.position = [
                region.uvMin.x * Float(namedAtlas.texture.width),
                region.uvMin.y * Float(namedAtlas.texture.height),
            ]

            super
                .init(
                    gpuTexture: namedAtlas.texture.gpuTexture,
                    sampler: namedAtlas.texture.sampler,
                    size: region.originalSize
                )
            self.assetMetaInfo = namedAtlas.texture.assetMetaInfo
            self.textureCoordinates = [
                [uvMin.x, uvMax.y],
                [uvMax.x, uvMax.y],
                [uvMax.x, uvMin.y],
                [uvMin.x, uvMin.y],
            ]
        }

        struct AssetError: LocalizedError {
            var errorDescription: String? {
                "Couldn't use named texture atlas slice as asset."
            }
        }

        enum CodingKeys: CodingKey {
            case namedAtlasResource
            case key
        }

        public required convenience init(from assetDecoder: any AssetDecoder) async throws {
            if let query = assetDecoder.assetMeta.queryParams.first {
                let key = query.value ?? query.name
                let namedAtlas = try await NamedTextureAtlas(from: assetDecoder)
                guard let region = namedAtlas.entriesByKey[key] else {
                    throw AssetDecodingError.decodingProblem("NamedTextureAtlas.Slice: missing key \(key).")
                }
                self.init(namedAtlas: namedAtlas, region: region)
                return
            }

            guard let container = try assetDecoder.decoder?.container(keyedBy: CodingKeys.self) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "Failed to decode \(Self.self). Decoder not passed.")
                )
            }
            let key = try container.decode(String.self, forKey: .key)
            let atlasDecoder = try container.superDecoder(forKey: .namedAtlasResource)
            let namedAtlas = try await assetDecoder.decode(NamedTextureAtlas.self, from: atlasDecoder)
            guard let region = namedAtlas.entriesByKey[key] else {
                throw AssetDecodingError.decodingProblem("NamedTextureAtlas.Slice: missing key \(key).")
            }
            self.init(namedAtlas: namedAtlas, region: region)
        }

        override public func encodeContents(with _: any AssetEncoder) async throws {
            throw AssetDecodingError.decodingProblem("NamedTextureAtlas.Slice: encoding not supported.")
        }
    }
}
