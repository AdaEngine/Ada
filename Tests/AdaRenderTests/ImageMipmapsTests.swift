import AdaRender
import Foundation
import Testing

@Suite
struct ImageMipmapsTests {
    @Test
    func sRGBDownsamplingAveragesLinearRadianceAndLinearAlpha() throws {
        let source = Image(width: 2, height: 1, data: Data([0, 0, 0, 0, 255, 255, 255, 255]), format: .rgba8)
        let color = try ImageMipmaps.make(from: source, colorSpace: .sRGB)
        let data = try ImageMipmaps.make(from: source, colorSpace: .linear)
        #expect(color.count == 2)
        #expect(color[1].data[0] == 188)
        #expect(color[1].data[3] == 128)
        #expect(data[1].data[0] == 128)
    }

    @Test
    func nonPowerOfTwoMipIncludesTheLastColumn() throws {
        let source = Image(width: 3, height: 1, data: Data([0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255]), format: .rgba8)
        let levels = try ImageMipmaps.make(from: source, colorSpace: .linear)
        #expect(levels[1].data[0] == 85)
        #expect(levels[1].width == 1)
    }

    @Test(arguments: [(1, 1), (4, 4), (7, 5), (16, 3), (33, 17)])
    func fastFilterMatchesReferenceAreaAverage(size: (Int, Int)) throws {
        var generator = SplitMix64(seed: UInt64(size.0 * 1_000 + size.1))
        for (format, components) in [(Image.Format.rgba8, 4), (.rgb8, 3), (.gray, 1), (.bgra8, 4)] {
            let bytes = (0 ..< size.0 * size.1 * components).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
            let image = Image(width: size.0, height: size.1, data: Data(bytes), format: format)
            for colorSpace in [ImageMipmaps.ColorSpace.sRGB, .linear] {
                for normalMap in [false, true] {
                    let fast = try ImageMipmaps.make(from: image, colorSpace: colorSpace, normalMap: normalMap)
                    let reference = Self.referenceMipmaps(image, components: components, sRGB: colorSpace == .sRGB, normalMap: normalMap)
                    #expect(fast.map(\.width) == reference.map(\.0))
                    #expect(fast.map(\.height) == reference.map(\.1))
                    #expect(fast.map { [UInt8]($0.data) } == reference.map(\.2))
                }
            }
        }
    }

    @Test
    func sRGBEncodingMatchesReferenceForEveryAverageOfTwoTexels() throws {
        // Every pair average exercises the sRGB rounding boundaries of the lookup encoder.
        var bytes: [UInt8] = []
        for first in 0 ... 255 {
            for second in stride(from: 0, through: 255, by: 3) {
                bytes += [UInt8(first), UInt8(second), UInt8(255 - first), 255, UInt8(second), UInt8(first), UInt8(first / 2), 0]
            }
        }
        let image = Image(width: 2, height: bytes.count / 8, data: Data(bytes), format: .rgba8)
        let fast = try ImageMipmaps.make(from: image, colorSpace: .sRGB, maximumLevelCount: 2)
        let reference = Self.referenceMipmaps(image, components: 4, sRGB: true, normalMap: false)
        #expect([UInt8](fast[1].data) == reference[1].2)
    }

    /// Deterministic generator so a failing size reproduces.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    /// The original per-texel implementation, kept as the behavioral reference.
    private static func referenceMipmaps(_ image: Image, components: Int, sRGB: Bool, normalMap: Bool) -> [(Int, Int, [UInt8])] {
        func decode(_ value: Float) -> Float {
            value <= 0.04045 ? value / 12.92 : Float(Foundation.pow(Double((value + 0.055) / 1.055), 2.4))
        }
        func encode(_ value: Float) -> Float {
            value <= 0.0031308 ? value * 12.92 : 1.055 * Float(Foundation.pow(Double(value), 1.0 / 2.4)) - 0.055
        }
        let source = Array(image.data)
        let rowBytes = source.count / image.height
        let bgra = image.format == .bgra8 || image.format == .bgra8_sRGB
        var rgba = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for y in 0 ..< image.height {
            for x in 0 ..< image.width {
                let src = y * rowBytes + x * components
                let dst = (y * image.width + x) * 4
                if components == 1 {
                    rgba[dst] = source[src]; rgba[dst + 1] = source[src]; rgba[dst + 2] = source[src]
                } else {
                    rgba[dst] = source[src + (bgra ? 2 : 0)]
                    rgba[dst + 1] = source[src + 1]
                    rgba[dst + 2] = source[src + (bgra ? 0 : 2)]
                    if components == 4 { rgba[dst + 3] = source[src + 3] }
                }
            }
        }
        var width = image.width
        var height = image.height
        var result = [(width, height, rgba)]
        while width > 1 || height > 1 {
            let nextWidth = max(1, width / 2)
            let nextHeight = max(1, height / 2)
            var next = [UInt8](repeating: 0, count: nextWidth * nextHeight * 4)
            for y in 0 ..< nextHeight {
                for x in 0 ..< nextWidth {
                    let startX = x * width / nextWidth, endX = (x + 1) * width / nextWidth
                    let startY = y * height / nextHeight, endY = (y + 1) * height / nextHeight
                    for channel in 0 ..< 4 {
                        var sum: Float = 0
                        for yy in startY ..< endY {
                            for xx in startX ..< endX {
                                let value = Float(rgba[(yy * width + xx) * 4 + channel]) / 255
                                sum += channel < 3 && sRGB ? decode(value) : value
                            }
                        }
                        let average = sum / Float((endX - startX) * (endY - startY))
                        let value = channel < 3 && sRGB ? encode(average) : average
                        next[(y * nextWidth + x) * 4 + channel] = UInt8(min(max((value * 255).rounded(), 0), 255))
                    }
                    if normalMap {
                        let offset = (y * nextWidth + x) * 4
                        let nx = Float(next[offset]) / 127.5 - 1
                        let ny = Float(next[offset + 1]) / 127.5 - 1
                        let nz = Float(next[offset + 2]) / 127.5 - 1
                        let length = (nx * nx + ny * ny + nz * nz).squareRoot()
                        let normal = length > 0.01 ? [nx / length, ny / length, nz / length] : [0, 0, 1]
                        for channel in 0..<3 {
                            next[offset + channel] = UInt8(min(max(((normal[channel] * 0.5 + 0.5) * 255).rounded(), 0), 255))
                        }
                    }
                }
            }
            width = nextWidth; height = nextHeight; rgba = next
            result.append((width, height, rgba))
        }
        return result
    }

    @Test
    func oldSamplerMetadataRetainsCompatibleDefaults() throws {
        let json = Data("{\"minFilter\":\"linear\",\"magFilter\":\"nearest\",\"mipFilter\":\"notMipmapped\",\"lodMinClamp\":0,\"lodMaxClamp\":1}".utf8)
        let sampler = try JSONDecoder().decode(SamplerDescriptor.self, from: json)
        #expect(sampler.minFilter == .linear)
        #expect(sampler.addressModeU == .clampToEdge)
        #expect(sampler.addressModeV == .clampToEdge)
    }
}
