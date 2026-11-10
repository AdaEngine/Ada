import Foundation

/// CPU mip generation used while importing glTF and terrain textures.
///
/// Each level is an area average of the previous 8-bit level. sRGB color channels are averaged
/// in linear space; alpha and `.linear` data are averaged directly.
public enum ImageMipmaps {
    public enum Error: Swift.Error, Sendable { case invalidSource }
    public enum ColorSpace: Sendable, Equatable { case linear, sRGB }

    public static func make(
        from image: Image,
        colorSpace: ColorSpace,
        includeMipmaps: Bool = true,
        maximumLevelCount: Int? = nil,
        normalMap: Bool = false
    ) throws -> [Image] {
        guard image.width > 0, image.height > 0, image.data.count.isMultiple(of: image.height) else {
            throw Error.invalidSource
        }
        let components = image.format == .rgb8 ? 3 : (image.format == .gray ? 1 : 4)
        let rowBytes = image.data.count / image.height
        guard rowBytes >= image.width * components else { throw Error.invalidSource }
        var width = image.width
        var height = image.height
        var rgba = expandToRGBA(image, components: components, rowBytes: rowBytes)
        var result = [Image(width: width, height: height, data: Data(rgba), format: .rgba8)]
        guard includeMipmaps else {
            return result
        }
        while (width > 1 || height > 1) && result.count < (maximumLevelCount ?? Int.max) {
            let nextWidth = max(1, width / 2)
            let nextHeight = max(1, height / 2)
            let next = downsample(rgba, width: width, height: height, nextWidth: nextWidth, nextHeight: nextHeight,
                                  sRGB: colorSpace == .sRGB, normalMap: normalMap)
            width = nextWidth; height = nextHeight; rgba = next
            result.append(Image(width: width, height: height, data: Data(rgba), format: .rgba8))
        }
        return result
    }

    private static func expandToRGBA(_ image: Image, components: Int, rowBytes: Int) -> [UInt8] {
        let width = image.width
        let height = image.height
        let bgra = image.format == .bgra8 || image.format == .bgra8_sRGB
        if components == 4 && !bgra && rowBytes == width * 4 && image.data.count == width * height * 4 {
            return [UInt8](image.data)
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        unsafe image.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            unsafe rgba.withUnsafeMutableBufferPointer { output in
                let source = unsafe raw.bindMemory(to: UInt8.self)
                for y in 0 ..< height {
                    for x in 0 ..< width {
                        let src = y * rowBytes + x * components
                        let dst = (y * width + x) * 4
                        if components == 1 {
                            let value = unsafe source[src]
                            unsafe output[dst] = value; unsafe output[dst + 1] = value; unsafe output[dst + 2] = value
                        } else {
                            unsafe output[dst] = source[src + (bgra ? 2 : 0)]
                            unsafe output[dst + 1] = source[src + 1]
                            unsafe output[dst + 2] = source[src + (bgra ? 0 : 2)]
                            if components == 4 { unsafe output[dst + 3] = source[src + 3] }
                        }
                    }
                }
            }
        }
        return rgba
    }

    // swiftlint:disable:next function_parameter_count
    private static func downsample(
        _ rgba: [UInt8], width: Int, height: Int, nextWidth: Int, nextHeight: Int, sRGB: Bool, normalMap: Bool
    ) -> [UInt8] {
        var next = [UInt8](repeating: 0, count: nextWidth * nextHeight * 4)
        let decode = sRGB ? SRGBTables.shared.decode : SRGBTables.shared.linear
        unsafe rgba.withUnsafeBufferPointer { source in
            unsafe next.withUnsafeMutableBufferPointer { output in
                for y in 0 ..< nextHeight {
                    // Area averaging also retains the last row/column of NPOT images.
                    let startY = y * height / nextHeight
                    let endY = (y + 1) * height / nextHeight
                    for x in 0 ..< nextWidth {
                        let startX = x * width / nextWidth
                        let endX = (x + 1) * width / nextWidth
                        let count = Float((endX - startX) * (endY - startY))
                        let offset = (y * nextWidth + x) * 4
                        for channel in 0 ..< 4 {
                            let table = channel < 3 ? decode : SRGBTables.shared.linear
                            var sum: Float = 0
                            for yy in startY ..< endY {
                                for xx in startX ..< endX {
                                    sum += unsafe table[Int(source[(yy * width + xx) * 4 + channel])]
                                }
                            }
                            let average = sum / count
                            unsafe output[offset + channel] = channel < 3 && sRGB
                                ? SRGBTables.shared.encode(average)
                                : UInt8(min(max((average * 255).rounded(), 0), 255))
                        }
                        if normalMap {
                            let nx = Float(unsafe output[offset]) / 127.5 - 1
                            let ny = Float(unsafe output[offset + 1]) / 127.5 - 1
                            let nz = Float(unsafe output[offset + 2]) / 127.5 - 1
                            let length = (nx * nx + ny * ny + nz * nz).squareRoot()
                            let normal = length > 0.01 ? [nx / length, ny / length, nz / length] : [0, 0, 1]
                            for channel in 0..<3 {
                                unsafe output[offset + channel] = UInt8(min(max(((normal[channel] * 0.5 + 0.5) * 255).rounded(), 0), 255))
                            }
                        }
                    }
                }
            }
        }
        return next
    }

    static func decodeSRGB(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : Float(Foundation.pow(Double((value + 0.055) / 1.055), 2.4))
    }

    static func encodeSRGB(_ value: Float) -> Float {
        value <= 0.0031308 ? value * 12.92 : 1.055 * Float(Foundation.pow(Double(value), 1.0 / 2.4)) - 0.055
    }
}

/// Lookup tables that reproduce `decodeSRGB`/`encodeSRGB` results for 8-bit values without per-texel `pow`.
private struct SRGBTables: Sendable {
    static let shared = SRGBTables()

    /// `decodeSRGB(Float(i) / 255)` for every 8-bit value.
    let decode: [Float]
    /// `Float(i) / 255` for every 8-bit value.
    let linear: [Float]
    /// Smallest linear value whose encoded byte rounds to at least `i + 1`, for `i` in `0..<255`.
    private let thresholds: [Float]

    private init() {
        decode = (0 ..< 256).map { ImageMipmaps.decodeSRGB(Float($0) / 255) }
        linear = (0 ..< 256).map { Float($0) / 255 }
        thresholds = (1 ..< 256).map { ImageMipmaps.decodeSRGB((Float($0) - 0.5) / 255) }
    }

    /// Equivalent to `UInt8(clamp((encodeSRGB(value) * 255).rounded(), 0, 255))`.
    func encode(_ value: Float) -> UInt8 {
        var low = 0
        var high = thresholds.count
        while low < high {
            let middle = (low + high) / 2
            if thresholds[middle] <= value { low = middle + 1 } else { high = middle }
        }
        // Near a rounding boundary the inverted threshold may differ in the last float bit; use the exact formula there.
        let near = (low > 0 && value - thresholds[low - 1] < 1e-5) || (low < thresholds.count && thresholds[low] - value < 1e-5)
        if near {
            return UInt8(min(max((ImageMipmaps.encodeSRGB(value) * 255).rounded(), 0), 255))
        }
        return UInt8(low)
    }
}
