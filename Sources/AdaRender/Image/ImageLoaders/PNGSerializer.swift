//
//  PNGSerializer.swift
//  AdaEngine
//
//  Created by v.prusakov on 6/29/22.
//

import Foundation
import libpng

/// An object that serialize png raw data to an ``Image``
struct PNGImageSerializer: ImageDecoder {
    enum DecodingError: String, Error {
        case cannotReadFromMemmory
        case cannotFinishReading
        case notSupportedImageFormat = "Unsupported png format"
    }

    let supportedExtensions = ["png"]

    func canDecode(_ data: Data) -> Bool {
        data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
    }

    func decode(_ data: Data) throws -> Image {
        var pngImage = unsafe png_image()
        unsafe pngImage.version = png_uint_32(PNG_IMAGE_VERSION)
        defer { unsafe png_image_free(&pngImage) }

        var isSuccess = unsafe data.withUnsafeBytes { bufferPtr in
            return unsafe png_image_begin_read_from_memory(&pngImage, bufferPtr.baseAddress, data.count) == 1
        }

        unsafe pngImage.format = PNG_FORMAT_FLAG_COLOR | PNG_FORMAT_FLAG_ALPHA

        let format: Image.Format = .rgba8

        if !isSuccess {
            throw DecodingError.cannotReadFromMemmory
        }

        let stride = unsafe swift_png_image_row_stride(pngImage)
        var imageBuffer = unsafe Data(count: Int(swift_png_image_buffer_size(pngImage, stride)))

        isSuccess = unsafe imageBuffer.withUnsafeMutableBytes {
            unsafe png_image_finish_read(&pngImage, nil, $0.baseAddress, png_int_32(stride), nil) == 1
        }

        if !isSuccess {
            throw DecodingError.cannotFinishReading
        }

        return unsafe Image(
            width: Int(pngImage.width),
            height: Int(pngImage.height),
            data: imageBuffer,
            format: format
        )
    }
}
