//
//  TextureDescriptor.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/25/23.
//

import Math

/// An object that you use to configure new texture objects.
public struct TextureDescriptor {
    /// The width of the texture image for the base level mipmap, in pixels.
    public var width: Int

    /// The height of the texture image for the base level mipmap, in pixels.
    public var height: Int

    /// The size and bit layout of all pixels in the texture.
    public var pixelFormat: PixelFormat

    /// Options that determine how you can use the texture.
    public var textureUsage: Texture.Usage

    /// The dimension and arrangement of texture image data.
    public var textureType: Texture.TextureType

    /// The number of mipmap levels for this texture.
    public var mipmapLevel: Int

    /// The data from we can create a texture.
    public var image: Image?

    /// The label marked texture for debug reason.
    public var debugLabel: String?

    /// The sampler that describe how to render a texture.
    public var samplerDescription: SamplerDescriptor

    /// Initialize a new texture descriptor.
    ///
    /// - Parameter width: The width of the texture image for the base level mipmap, in pixels.
    /// - Parameter height: The height of the texture image for the base level mipmap, in pixels.
    /// - Parameter pixelFormat: The size and bit layout of all pixels in the texture.
    /// - Parameter textureUsage: Options that determine how you can use the texture.
    /// - Parameter textureType: The dimension and arrangement of texture image data.
    /// - Parameter mipmapLevel: The number of mipmap levels for this texture.
    /// - Parameter image: The data from we can create a texture.
    /// - Parameter debugLabel: The label marked texture for debug reason.
    /// - Parameter samplerDescription: The sampler that describe how to render a texture.
    public init(
        width: Int = 1,
        height: Int = 1,
        pixelFormat: PixelFormat = .bgra8,
        textureUsage: Texture.Usage,
        textureType: Texture.TextureType,
        mipmapLevel: Int = 0,
        image: Image? = nil,
        debugLabel: String? = nil,
        samplerDescription: SamplerDescriptor = SamplerDescriptor()
    ) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.textureUsage = textureUsage
        self.textureType = textureType
        self.mipmapLevel = mipmapLevel
        self.debugLabel = debugLabel
        self.image = image
        self.samplerDescription = samplerDescription
    }
}

/// Interface represent platform specific gpu texture.
public protocol GPUTexture: AnyObject {
    var size: SizeInt { get }
    var label: String? { get set }

    /// Replace a region of the texture with new data.
    func replaceRegion(_ region: RectInt, mipmapLevel: Int, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int)
}
