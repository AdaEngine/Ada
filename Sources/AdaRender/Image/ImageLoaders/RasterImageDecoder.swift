import CImageDecoder
import Foundation

/// Portable memory-only decoding for JPEG, BMP and TGA.
struct RasterImageDecoder: ImageDecoder {
    let supportedExtensions = ["jpg", "jpeg", "tga", "bmp"]

    func canDecode(_ data: Data) -> Bool {
        guard !data.isEmpty, let length = Int32(exactly: data.count) else {
            return false
        }
        return unsafe data.withUnsafeBytes { bytes in
            unsafe ada_image_can_decode(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), length) != 0
        }
    }

    func decode(_ data: Data) throws -> Image {
        guard let length = Int32(exactly: data.count) else {
            throw ImageDecodingError.inputTooLarge
        }
        var width: Int32 = 0
        var height: Int32 = 0
        let decodedPixels = unsafe data.withUnsafeBytes { bytes in
            unsafe ada_image_decode(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), length, &width, &height)
        }
        guard let pixels = unsafe decodedPixels else {
            throw ImageDecodingError.invalidData
        }
        defer { unsafe ada_image_free(pixels) }

        return unsafe Image(
            width: Int(width),
            height: Int(height),
            data: Data(bytes: pixels, count: Int(width) * Int(height) * 4),
            format: .rgba8
        )
    }
}
