import Foundation

/// Decodes an external raster format into CPU image pixels.
///
/// Register implementations with ``Image/registerDecoder(_:)`` before loading assets.
/// Implementations must allow concurrent calls and identify their input from its bytes.
public protocol ImageDecoder: Sendable {
    /// File extensions accepted by this decoder, without leading dots.
    var supportedExtensions: [String] { get }

    /// Whether the bytes appear to belong to this decoder's format.
    /// A positive result does not guarantee that the complete image is valid.
    func canDecode(_ data: Data) -> Bool

    /// Decodes a complete image, throwing if its contents are invalid.
    func decode(_ data: Data) throws -> Image
}

/// Errors produced while selecting or invoking an image decoder.
public enum ImageDecodingError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case invalidData
    case inputTooLarge

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(fileExtension):
            return "No image decoder supports the format \"\(fileExtension)\"."
        case .invalidData:
            return "The image data is invalid or its format is unsupported."
        case .inputTooLarge:
            return "The image data exceeds the decoder's supported size."
        }
    }
}
