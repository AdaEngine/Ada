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

    @Test
    func oldSamplerMetadataRetainsCompatibleDefaults() throws {
        let json = Data("{\"minFilter\":\"linear\",\"magFilter\":\"nearest\",\"mipFilter\":\"notMipmapped\",\"lodMinClamp\":0,\"lodMaxClamp\":1}".utf8)
        let sampler = try JSONDecoder().decode(SamplerDescriptor.self, from: json)
        #expect(sampler.minFilter == .linear)
        #expect(sampler.addressModeU == .clampToEdge)
        #expect(sampler.addressModeV == .clampToEdge)
    }
}
