import AdaUtils
import Foundation

/// Portable import settings stored next to an image as `<image filename>.texture.json`.
/// Images without this file retain their existing loading behavior.
public struct TextureImportSettings: Codable, Equatable, Sendable {
    public enum Dimension: String, Codable, CaseIterable, Sendable { case texture2D, cube }
    public enum Purpose: String, Codable, CaseIterable, Sendable { case color, normal, data }
    public enum ColorSpace: String, Codable, CaseIterable, Sendable { case automatic, linear, sRGB }

    public var version = 1
    public var dimension: Dimension = .texture2D
    public var purpose: Purpose = .color
    public var colorSpace: ColorSpace = .automatic
    public var generateMipmaps = false
    /// Includes level zero. Zero selects the full chain when mipmap generation is enabled.
    public var mipLevelCount = 0
    public var sampler = SamplerDescriptor()

    public init() {}

    public var usesSRGB: Bool {
        purpose == .color && (colorSpace == .sRGB || colorSpace == .automatic)
    }

    public static func sidecarURL(for imageURL: URL) -> URL {
        imageURL.appendingPathExtension("texture.json")
    }

    /// Reads through the active filesystem, including virtual project resource roots.
    public static func load(for imageURL: URL) throws -> Self? {
        let url = sidecarURL(for: imageURL)
        guard FileSystem.current.itemExists(at: url) else {
            return nil
        }
        guard let data = FileSystem.current.readFile(at: url) else { throw ImportError.unreadableSettings }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func maximumMipLevelCount(for image: Image) -> Int {
        var size = max(dimension == .cube ? image.height : image.width, image.height)
        var count = 1
        while size > 1 {
            size /= 2
            count += 1
        }
        return count
    }

    public func validate(for image: Image) throws {
        guard version == 1 else { throw ImportError.unsupportedVersion }
        guard image.width > 0, image.height > 0 else { throw ImportError.invalidImage }
        guard dimension != .cube || image.width / 6 == image.height && image.width.isMultiple(of: 6) else {
            throw ImportError.cubeLayout
        }
        guard mipLevelCount >= 0, mipLevelCount <= maximumMipLevelCount(for: image) else { throw ImportError.mipCount }
        guard sampler.lodMinClamp.isFinite, sampler.lodMaxClamp.isFinite,
            sampler.lodMinClamp >= 0, sampler.lodMaxClamp >= sampler.lodMinClamp
        else { throw ImportError.lodRange }
        guard purpose == .color || colorSpace != .sRGB else { throw ImportError.linearData }
    }

    /// Converts pixels, generates populated mip levels, and splits a six-face horizontal cube strip.
    public func prepare(_ image: Image) throws -> ImportedTextureData {
        try validate(for: image)
        let normalized = try ImageMipmaps.make(from: image, colorSpace: .linear, includeMipmaps: false)[0]
        let faces: [Image]
        if dimension == .cube {
            let size = normalized.height
            let bytes = Array(normalized.data)
            faces = (0..<6).map { face in
                var data = Data(capacity: size * size * 4)
                for row in 0..<size {
                    let offset = (row * normalized.width + face * size) * 4
                    data.append(contentsOf: bytes[offset..<(offset + size * 4)])
                }
                return Image(width: size, height: size, data: data)
            }
        } else {
            faces = [normalized]
        }
        let levels = try faces.map { face in
            try ImageMipmaps.make(
                from: face,
                colorSpace: usesSRGB ? .sRGB : .linear,
                includeMipmaps: generateMipmaps,
                maximumLevelCount: mipLevelCount == 0 ? nil : mipLevelCount,
                normalMap: purpose == .normal
            ).map { level in
                guard usesSRGB else {
                    return level
                }
                var bytes = Array(level.data)
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    bytes.swapAt(offset, offset + 2)
                }
                return Image(width: level.width, height: level.height, data: Data(bytes), format: .bgra8_sRGB)
            }
        }
        return ImportedTextureData(settings: self, faces: levels)
    }

    public enum ImportError: LocalizedError {
        case unsupportedVersion, unreadableSettings, invalidImage, cubeLayout, mipCount, lodRange, linearData, requiresCubeLoader

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "Unsupported texture settings version."
            case .unreadableSettings: "Cannot read texture settings."
            case .invalidImage: "Texture image dimensions must be positive."
            case .cubeLayout: "Cube requires six square faces in a horizontal strip: +X, -X, +Y, -Y, +Z, -Z."
            case .mipCount: "Mip level count must be zero (automatic) or fit the image dimensions."
            case .lodRange: "LOD must be finite and satisfy 0 ≤ Min ≤ Max."
            case .linearData: "Normal and Data textures require Linear or Automatic color space."
            case .requiresCubeLoader: "Use TextureCube to load a Cube texture. Sprites and skybox panoramas require 2D."
            }
        }
    }
}

/// Immutable CPU import result shared by preview and GPU upload. Faces contain level zero first.
public struct ImportedTextureData: Sendable {
    public let settings: TextureImportSettings
    public let faces: [[Image]]

    public var descriptor: TextureDescriptor {
        let base = faces[0][0]
        var descriptor = TextureDescriptor(
            width: base.width,
            height: base.height,
            pixelFormat: base.format.toPixelFormat,
            textureUsage: [.read],
            textureType: settings.dimension == .cube ? .textureCube : .texture2D,
            mipmapLevel: faces[0].count,
            image: base,
            samplerDescription: settings.sampler
        )
        descriptor.subresources = faces.enumerated().flatMap { slice, levels in
            levels.enumerated().compactMap { level, image in
                slice == 0 && level == 0 ? nil : TextureSubresource(image: image, mipLevel: level, slice: slice)
            }
        }
        return descriptor
    }
}
