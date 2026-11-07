import Foundation

enum TextureSubresourceUploadError: LocalizedError {
    case invalidSubresource, unsupportedBackend

    var errorDescription: String? {
        switch self {
        case .invalidSubresource: "Texture upload requires a complete RGBA8 image matching an allocated array slice and mip level"
        case .unsupportedBackend: "This rendering backend does not support incremental texture subresource uploads"
        }
    }
}

/// Backend implementation receives only images checked against their allocated layout.
protocol TextureSubresourceUploading {
    func uploadSubresource(_ resource: TextureSubresource) throws
}

extension Texture2D {
    /// Initializes one existing RGBA8 slice/mip without allocating another texture or replacing its sampler.
    /// The caller must keep staged textures private until all sampled subresources are initialized.
    @_spi(Internal)
    public func uploadSubresource(_ resource: TextureSubresource) throws {
        // Retain one concrete backing and its layout for the complete upload, even
        // when another producer replaces the proxy source during this call.
        let source = (self as? Texture2DProxy)?.backingSource() ?? self
        let image = resource.image
        guard source.textureType == .texture2D || source.textureType == .texture2DArray,
            source.subresourcePixelFormat == .rgba8, image.format.toPixelFormat == .rgba8,
            source.width > 0, source.height > 0, (0..<source.subresourceArrayLength).contains(resource.slice),
            (0..<source.mipmapLevelCount).contains(resource.mipLevel),
            image.width == max(1, source.width >> resource.mipLevel), image.height == max(1, source.height >> resource.mipLevel)
        else { throw TextureSubresourceUploadError.invalidSubresource }
        let area = image.width.multipliedReportingOverflow(by: image.height)
        let bytes = area.partialValue.multipliedReportingOverflow(by: 4)
        guard !area.overflow, !bytes.overflow, bytes.partialValue > 0, image.data.count == bytes.partialValue else {
            throw TextureSubresourceUploadError.invalidSubresource
        }
        guard let destination = unsafe source.gpuTexture as? any TextureSubresourceUploading else { throw TextureSubresourceUploadError.unsupportedBackend }
        try destination.uploadSubresource(resource)
        source.invalidatePickingAlphaMask()
    }
}
