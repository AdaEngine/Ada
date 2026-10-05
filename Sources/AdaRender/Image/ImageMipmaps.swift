import Foundation

/// CPU reference mip generation used while importing small glTF textures.
public enum ImageMipmaps {
    public enum Error: Swift.Error, Sendable { case invalidSource }
    public enum ColorSpace: Sendable, Equatable { case linear, sRGB }

    public static func make(from image: Image, colorSpace: ColorSpace, includeMipmaps: Bool = true) throws -> [Image] {
        guard image.width > 0, image.height > 0, image.data.count.isMultiple(of: image.height) else {
            throw Error.invalidSource
        }
        let components = image.format == .rgb8 ? 3 : (image.format == .gray ? 1 : 4)
        let rowBytes = image.data.count / image.height
        guard rowBytes >= image.width * components else { throw Error.invalidSource }
        let source = Array(image.data)
        var rgba = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for y in 0 ..< image.height {
            for x in 0 ..< image.width {
                let src = y * rowBytes + x * components
                let dst = (y * image.width + x) * 4
                if components == 1 {
                    rgba[dst] = source[src]; rgba[dst + 1] = source[src]; rgba[dst + 2] = source[src]
                } else {
                    let bgra = image.format == .bgra8 || image.format == .bgra8_sRGB
                    rgba[dst] = source[src + (bgra ? 2 : 0)]
                    rgba[dst + 1] = source[src + 1]
                    rgba[dst + 2] = source[src + (bgra ? 0 : 2)]
                    if components == 4 { rgba[dst + 3] = source[src + 3] }
                }
            }
        }
        var width = image.width
        var height = image.height
        var result = [Image(width: width, height: height, data: Data(rgba), format: .rgba8)]
        guard includeMipmaps else {
            return result
        }
        while width > 1 || height > 1 {
            let nextWidth = max(1, width / 2)
            let nextHeight = max(1, height / 2)
            var next = [UInt8](repeating: 0, count: nextWidth * nextHeight * 4)
            for y in 0 ..< nextHeight {
                for x in 0 ..< nextWidth {
                    // Area averaging also retains the last row/column of NPOT images.
                    let startX = x * width / nextWidth
                    let endX = (x + 1) * width / nextWidth
                    let startY = y * height / nextHeight
                    let endY = (y + 1) * height / nextHeight
                    for channel in 0 ..< 4 {
                        var sum: Float = 0
                        for yy in startY ..< endY {
                            for xx in startX ..< endX {
                                let value = Float(rgba[(yy * width + xx) * 4 + channel]) / 255
                                sum += channel < 3 && colorSpace == .sRGB ? decodeSRGB(value) : value
                            }
                        }
                        let count = Float((endX - startX) * (endY - startY))
                        let average = sum / count
                        let value = channel < 3 && colorSpace == .sRGB ? encodeSRGB(average) : average
                        next[(y * nextWidth + x) * 4 + channel] = UInt8(min(max((value * 255).rounded(), 0), 255))
                    }
                }
            }
            width = nextWidth; height = nextHeight; rgba = next
            result.append(Image(width: width, height: height, data: Data(rgba), format: .rgba8))
        }
        return result
    }

    private static func decodeSRGB(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : Float(Foundation.pow(Double((value + 0.055) / 1.055), 2.4))
    }

    private static func encodeSRGB(_ value: Float) -> Float {
        value <= 0.0031308 ? value * 12.92 : 1.055 * Float(Foundation.pow(Double(value), 1.0 / 2.4)) - 0.055
    }
}
