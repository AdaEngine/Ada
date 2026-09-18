//
//  RenderTexture.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/28/23.
//

// FIXME: (Vlad) should say that texture isn't use for rendering anymore
// FIXME: (Vlad) I feel that we have a bug with deinitialization here

import AdaAssets
import AdaUtils
import Math

/// A texture using as a render target.
public final class RenderTexture: Texture2D, @unchecked Sendable {
    /// The pixel format of the texture.
    public let pixelFormat: PixelFormat

    /// The scale factor of the texture.
    public let scaleFactor: Float

    /// A Boolean value indicating whether the texture is active.
    public private(set) var isActive: Bool = true

    @_spi(Internal)
    public var renderCompletedHandler: (@Sendable (RenderTexture) -> Void)?

    /// Initialize a new render texture.
    ///
    /// - Parameters:
    ///   - size: The size of the texture.
    ///   - scaleFactor: The scale factor of the texture.
    ///   - format: The pixel format of the texture.
    public init(
        size: SizeInt,
        scaleFactor: Float,
        format: PixelFormat,
        debugLabel: String? = nil,
        samplerDescription: SamplerDescriptor = SamplerDescriptor()
    ) {
        let descriptor = TextureDescriptor(
            width: size.width,
            height: size.height,
            pixelFormat: format,
            textureUsage: [.renderTarget, .read],
            textureType: .texture2D,
            debugLabel: debugLabel,
            samplerDescription: samplerDescription
        )

        self.pixelFormat = format
        self.scaleFactor = scaleFactor

        let device = unsafe RenderEngine.shared.renderDevice
        let gpuTexture = device.createTexture(from: descriptor)
        let sampler = device.createSampler(from: descriptor.samplerDescription)

        super.init(gpuTexture: gpuTexture, sampler: sampler, size: size)
    }

    /// Initialize a new render texture from a decoder.
    ///
    /// - Parameter decoder: The decoder to initialize the render texture from.
    /// - Throws: An error if the render texture cannot be initialized from the decoder.
    public required init(from _: any AssetDecoder) async throws {
        throw AssetError.message("RenderTexture cannot be decoded as an asset.")
    }

    /// Initialize a new render texture from a GPU texture.
    internal init(gpuTexture: GPUTexture, format: PixelFormat, scaleFactor: Float = 1.0) {
        self.pixelFormat = format
        self.scaleFactor = scaleFactor

        let device = unsafe RenderEngine.shared.renderDevice
        let sampler = device.createSampler(from: SamplerDescriptor())

        super.init(gpuTexture: gpuTexture, sampler: sampler, size: gpuTexture.size)
    }

    func setActive(_ isActive: Bool) {
        self.isActive = isActive
    }

    @_spi(Internal)
    public func notifyRenderCompleted() {
        renderCompletedHandler?(self)
    }
}
