//
//  Texture.swift
//  AdaEngine
//
//  Created by v.prusakov on 6/28/22.
//

import AdaAssets
@_spi(Runtime) import AdaUtils

/// Base class describing a texture.
open class Texture: Asset, @unchecked Sendable, CustomStringConvertible {
    @_spi(Internal)
    public private(set) var gpuTexture: GPUTexture

    /// The sampler instance that describe how to render texture.
    public private(set) var sampler: Sampler

    private(set) var textureType: TextureType

    public var assetMetaInfo: AssetMetaInfo?

    init(gpuTexture: GPUTexture, sampler: Sampler, textureType: TextureType) {
        self.gpuTexture = gpuTexture
        self.textureType = textureType
        self.sampler = sampler
    }

    internal var assetDescription: String {
        if let assetMetaInfo {
            if !assetMetaInfo.assetName.isEmpty {
                return "asset=\(assetMetaInfo.assetName)"
            }

            if !assetMetaInfo.assetPath.isEmpty {
                return "asset=\(assetMetaInfo.assetPath)"
            }
        }

        return "asset=none"
    }

    internal var samplerDescription: String {
        let desc = self.sampler.descriptor
        return "sampler=min=\(desc.minFilter) mag=\(desc.magFilter) mip=\(desc.mipFilter) lod=[\(desc.lodMinClamp), \(desc.lodMaxClamp)]"
    }

    internal var memoryAddressDescription: String {
        let address = unsafe Unmanaged.passUnretained(self).toOpaque()
        return unsafe "address=\(address)"
    }

    open var description: String {
        let typeName = String(reflecting: Swift.type(of: self))
        return "\(typeName)(type=\(self.textureType), \(self.assetDescription), \(self.samplerDescription), \(self.memoryAddressDescription))"
    }

    /// Returns an ``Image`` instance.
    public var image: Image {
        if let texture2D = self as? Texture2D {
            return Image(texture: texture2D)
        }

        if let image = unsafe RenderEngine.shared.renderDevice.getImage(from: self) {
            return image
        }

        return Image()
    }

    public required init(from _: any AssetDecoder) async throws {
        fatalErrorMethodNotImplemented()
    }

    public func encodeContents(with _: any AssetEncoder) async throws {
        fatalErrorMethodNotImplemented()
    }

    public static func extensions() -> [String] {
        return ["tex"]
    }
}

extension Texture {
    /// The dimension of each image, including whether multiple images are arranged into an array or a cube.
    public enum TextureType: UInt16, Codable, Sendable {
        /// A one-dimensional texture image.
        case texture1D

        /// An array of one-dimensional texture images.
        case texture1DArray

        /// A two-dimensional texture image.
        case texture2D

        /// An array of two-dimensional texture images.
        case texture2DArray

        /// A two-dimensional texture image that uses more than one sample for each pixel.
        case texture2DMultisample

        /// An array of two-dimensional texture images that use more than one sample for each pixel.
        case texture2DMultisampleArray

        /// A cube texture with six two-dimensional images.
        case textureCube

        /// A three-dimensional texture image.
        case texture3D

        /// A texture buffer.
        case textureBuffer
    }

    /// An enumeration for the various options that determine how you can use a texture.
    public struct Usage: OptionSet, Codable, Sendable {
        public typealias RawValue = UInt8

        public var rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// An option for reading or sampling from the texture in a shader.
        public static let read = Self(rawValue: 1 << 0)

        /// An option for writing to the texture in a shader.
        public static let write = Self(rawValue: 1 << 1)

        /// An option for rendering to the texture in a render pass.
        public static let renderTarget = Self(rawValue: 1 << 2)
    }
}

// MARK: - RuntimeRegistrable

@_spi(Runtime)
extension Texture: RuntimeRegistrable {
    @MainActor private(set) static var types: [String: Texture.Type] = [:]

    @MainActor
    static func registerTextureType() {
        types[String(reflecting: type(of: self))] = Self.self
    }

    @MainActor
    public static func registerTypes() {
        AssetsManager.registerAssetType(Texture2D.self)
        AssetsManager.registerAssetType(TextureAtlas.self)
        AssetsManager.registerAssetType(TextureAtlas.Slice.self)
        AssetsManager.registerAssetType(AnimatedTexture.self)
        AssetsManager.registerAssetType(NamedTextureAtlas.self)
        AssetsManager.registerAssetType(NamedTextureAtlas.Slice.self)

        Texture2D.registerTextureType()
        TextureAtlas.registerTextureType()
        AnimatedTexture.registerTextureType()
    }
}
