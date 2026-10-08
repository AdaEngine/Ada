//
//  Image+CoreGraphics.swift
//  AdaEngine
//

#if canImport(CoreGraphics)
    import CoreGraphics
    import Foundation

    extension Image {
        /// Creates an RGBA8 image from an Apple Core Graphics image.
        public init(cgImage: CGImage) {
            let width = cgImage.width
            let height = cgImage.height
            let bytesPerRow = width * 4
            var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo =
                CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue

            let context = unsafe pixels.withUnsafeMutableBytes { bytes in
                CGContext(
                    data: bytes.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            }
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            self.init(width: width, height: height, data: Data(pixels), format: .rgba8)
        }
    }
#endif
