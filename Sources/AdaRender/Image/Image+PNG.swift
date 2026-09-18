#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO
    import UniformTypeIdentifiers

    public enum ImagePNGEncodingError: LocalizedError {
        case unsupportedFormat(Image.Format)
        case failedToCreateImage
        case failedToCreateDestination(URL)
        case failedToFinalizeDestination(URL)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedFormat(format):
                return "Unsupported image format for PNG encoding: \(format)"
            case .failedToCreateImage:
                return "Failed to create CGImage for PNG encoding."
            case let .failedToCreateDestination(url):
                return "Failed to create PNG destination at \(url.path)."
            case let .failedToFinalizeDestination(url):
                return "Failed to finalize PNG destination at \(url.path)."
            }
        }
    }

    extension Image {
        public func pngData() throws -> Data {
            let rgbaData = try self.pngCompatibleRGBAData()
            let provider = CGDataProvider(data: rgbaData as CFData)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)

            guard
                let provider,
                let cgImage = CGImage(
                    width: self.width,
                    height: self.height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: self.width * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo,
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                )
            else {
                throw ImagePNGEncodingError.failedToCreateImage
            }

            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    data,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                )
            else {
                throw ImagePNGEncodingError.failedToCreateDestination(URL(fileURLWithPath: "memory"))
            }

            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ImagePNGEncodingError.failedToFinalizeDestination(URL(fileURLWithPath: "memory"))
            }

            return data as Data
        }

        public func writePNG(to url: URL) throws {
            let data = try self.pngData()
            try data.write(to: url, options: .atomic)
        }

        private func pngCompatibleRGBAData() throws -> Data {
            switch self.format {
            case .rgba8:
                return self.data
            case .bgra8,
                .bgra8_sRGB:
                var data = self.data
                data.withUnsafeMutableBytes { bytes in
                    guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    for offset in stride(from: 0, to: bytes.count, by: 4) {
                        let blue = base[offset]
                        base[offset] = base[offset + 2]
                        base[offset + 2] = blue
                    }
                }
                return data
            case .rgb8:
                var result = Data(capacity: self.width * self.height * 4)
                for offset in stride(from: 0, to: self.data.count, by: 3) {
                    result.append(self.data[offset])
                    result.append(self.data[offset + 1])
                    result.append(self.data[offset + 2])
                    result.append(255)
                }
                return result
            case .gray:
                var result = Data(capacity: self.width * self.height * 4)
                for value in self.data {
                    result.append(value)
                    result.append(value)
                    result.append(value)
                    result.append(255)
                }
                return result
            }
        }
    }
#endif
