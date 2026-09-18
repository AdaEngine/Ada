//
//  Image.swift
//  AdaEngine
//
//  Created by v.prusakov on 6/28/22.
//

import AdaAssets
import AdaUtils
import Foundation
import Math

/// An object that manages image data in your app.
public struct Image: Sendable {
    public private(set) var data: Data

    public private(set) var height: Int
    public private(set) var width: Int

    @_spi(Internal)
    public var options: [String: any Sendable] = [:]

    // TODO: Replace it to PixelFormat
    public private(set) var format: Format

    public var assetMetaInfo: AssetMetaInfo?
    public var samplerDescription: SamplerDescriptor = SamplerDescriptor()

    /// Create an empty image.
    public init() {
        self.data = Data()
        self.height = 1
        self.width = 1
        self.format = .rgba8
    }

    /// Create an image with given height and width.
    /// - Parameter width: The image width.
    /// - Parameter height: The image height.
    /// - Parameter data: Data passed to the image, but if you will pass nil, than image with fill with 0.
    /// - Parameter format: The image format. Default value is `Image.Format.rgba8`
    public init(width: Int, height: Int, data: Data? = nil, format: Format = .rgba8) {
        assert(width > 0, "Width must be greater than 0.")
        assert(height > 0, "Height must be greater than 0.")

        self.data = data ?? Self.makeEmptyData(for: format, width: width, height: height)
        self.width = width
        self.height = height
        self.format = format
    }

    public init(width: Int, height: Int, color: Color, format: Format = .rgba8) {
        assert(width > 0, "Width must be greater than 0.")
        assert(height > 0, "Height must be greater than 0.")

        self.data = Self.makeEmptyData(for: format, width: width, height: height, color: color)
        self.width = width
        self.height = height
        self.format = format
    }

    /// Create an image by reading pixel data from a texture.
    ///
    /// If the active render backend can't read the texture data, this initializer returns an empty image.
    public init(texture: Texture2D) {
        if var image = unsafe RenderEngine.shared.renderDevice.getImage(from: texture) {
            image.assetMetaInfo = texture.assetMetaInfo
            image.samplerDescription = texture.sampler.descriptor
            self = image
            return
        }

        self.init()
        self.assetMetaInfo = texture.assetMetaInfo
        self.samplerDescription = texture.sampler.descriptor
    }

    /// Set pixel color for specific X and Y position.
    public mutating func setPixel(in position: Point, color: Color) {
        let offset = Int(position.y) * self.width + Int(position.x)

        Self.setPixel(with: offset, color: color, in: &self.data, format: self.format)
    }

    /// Get pixel color for specific X and Y position.
    public func getPixel(x: Int, y: Int) -> Color {
        let offset = y * self.width + x
        switch self.format {
        case .rgb8:
            let red = Float(self.data[offset * 3 + 0]) / 255
            let green = Float(self.data[offset * 3 + 1]) / 255
            let blue = Float(self.data[offset * 3 + 2]) / 255
            return Color(red, green, blue, 1)
        case .rgba8:
            let red = Float(self.data[offset * 4 + 0]) / 255
            let green = Float(self.data[offset * 4 + 1]) / 255
            let blue = Float(self.data[offset * 4 + 2]) / 255
            let alpha = Float(self.data[offset * 4 + 3]) / 255
            return Color(red, green, blue, alpha)
        case .bgra8:
            let blue = Float(self.data[offset * 4 + 0]) / 255
            let green = Float(self.data[offset * 4 + 1]) / 255
            let red = Float(self.data[offset * 4 + 2]) / 255
            let alpha = Float(self.data[offset * 4 + 3]) / 255
            return Color(red, green, blue, alpha)
        default:
            fatalError("Not supported format to get pixel.")
        }
    }
}

extension Image {
    public enum Format: UInt16, Codable, Sendable {
        case rgba8
        case rgb8
        case bgra8
        case bgra8_sRGB
        case gray
    }
}

extension Image {
    private enum LoadingError: LocalizedError {
        case formatNotSupported(String)
        case readFileFailedAtPath(URL)

        var errorDescription: String? {
            switch self {
            case let .formatNotSupported(format):
                return "Image with format \"\(format)\" not supported."
            case let .readFileFailedAtPath(path):
                return "Can't read file at path \(path.absoluteString)."
            }
        }
    }

    private static let loaders: [ImageLoaderStrategy] = [
        PNGImageSerializer()
    ]

    public init(contentsOf file: URL) throws {
        guard let loader = Self.loaders.first(where: { $0.canDecodeImage(with: file.pathExtension) }) else {
            throw LoadingError.formatNotSupported(file.pathExtension)
        }

        guard let data = FileSystem.current.readFile(at: file) else {
            throw LoadingError.readFileFailedAtPath(file)
        }

        let image = try loader.decodeImage(from: data)

        self.init(
            width: image.width,
            height: image.height,
            data: image.data,
            format: image.format
        )
    }

    /// Decode image from data.
    /// - Parameter data: Image data.
    /// - Returns: Decoded image.
    public static func decode(from data: Data) throws -> Image {
        // FIXME: (Vlad) We should detect the format of the image.
        let loader = PNGImageSerializer()
        return try loader.decodeImage(from: data)
    }
}

extension Image: Asset {
    private struct ImageRepresentation: Codable {
        let imageSize: Size
        let data: Data
        let colorFormat: Format
        let sampler: SamplerDescriptor
    }

    public init(from assetDecoder: AssetDecoder) async throws {
        let pathExt = assetDecoder.assetMeta.filePath.pathExtension

        if pathExt.isEmpty || pathExt == "res" {
            let rep = try assetDecoder.decode(ImageRepresentation.self)

            self.init(
                width: Int(rep.imageSize.width),
                height: Int(rep.imageSize.height),
                data: rep.data,
                format: rep.colorFormat
            )

            self.samplerDescription = rep.sampler
        } else {
            try self.init(contentsOf: assetDecoder.assetMeta.filePath)
        }
    }

    public func encodeContents(with encoder: AssetEncoder) throws {
        let pathExt = encoder.assetMeta.filePath.pathExtension

        if pathExt.isEmpty || pathExt == "res" {
            let rep = ImageRepresentation(
                imageSize: Size(width: Float(width), height: Float(height)),
                data: self.data,
                colorFormat: self.format,
                sampler: self.samplerDescription
            )

            try encoder.encode(rep)
        } else {
            try encoder.encode(self.data)
        }
    }

    public static func extensions() -> [String] {
        ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp"]
    }
}

extension Image {
    private static func makeEmptyData(
        for format: Format,
        width: Int,
        height: Int,
        color: Color? = nil
    ) -> Data {
        let stride = self.getPixelSize(for: format)
        let size = width * height
        var data = Data(repeating: 0, count: size * stride)

        guard let color else {
            return data
        }

        var currentIndex = 0

        while currentIndex < size {
            Self.setPixel(with: currentIndex, color: color, in: &data, format: format)
            currentIndex += 1
        }

        return data
    }

    private static func getPixelSize(for format: Format) -> Int {
        switch format {
        case .rgba8,
            .bgra8,
            .bgra8_sRGB:
            return 4
        case .rgb8:
            return 3
        case .gray:
            return 1
        }
    }

    private static func setPixel(with offset: Int, color: Color, in data: inout Data, format: Format) {
        switch format {
        case .rgb8:
            data[offset * 3 + 0] = UInt8(clamp(color.red * 255.0, 0, 255))
            data[offset * 3 + 1] = UInt8(clamp(color.green * 255.0, 0, 255))
            data[offset * 3 + 2] = UInt8(clamp(color.blue * 255.0, 0, 255))
        case .rgba8:
            data[offset * 4 + 0] = UInt8(clamp(color.red * 255.0, 0, 255))
            data[offset * 4 + 1] = UInt8(clamp(color.green * 255.0, 0, 255))
            data[offset * 4 + 2] = UInt8(clamp(color.blue * 255.0, 0, 255))
            data[offset * 4 + 3] = UInt8(clamp(color.alpha * 255.0, 0, 255))
        case .bgra8:
            data[offset * 4 + 0] = UInt8(clamp(color.blue * 255.0, 0, 255))
            data[offset * 4 + 1] = UInt8(clamp(color.green * 255.0, 0, 255))
            data[offset * 4 + 2] = UInt8(clamp(color.red * 255.0, 0, 255))
            data[offset * 4 + 3] = UInt8(clamp(color.alpha * 255.0, 0, 255))
        default:
            fatalError("Not supported type for set pixel")
        }
    }
}

extension Image.Format {
    public var toPixelFormat: PixelFormat {
        switch self {
        case .rgba8:
            return .rgba8
        case .rgb8:
            return .rgba8
        case .bgra8:
            return .bgra8
        case .bgra8_sRGB:
            return .bgra8_srgb
        case .gray:
            return .none
        }
    }
}
