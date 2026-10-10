import AdaAssets
import Foundation
import Testing

@_spi(Internal) @testable import AdaRender

#if canImport(Metal)
    import Metal
#endif

@Suite("Texture import settings", .serialized)
struct TextureImportSettingsTests {
    @Test
    func samplerAndMipLevelsSurviveRealResourceLoading() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("texture-import-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("image.tga")
        // Portable, top-origin BGRA8 TGA; does not require Apple's PNG encoder.
        var header = [UInt8](repeating: 0, count: 18)
        header[2] = 2
        header[12] = 8
        header[14] = 4
        header[16] = 32
        header[17] = 0x28
        try (Data(header) + Data(repeating: 255, count: 8 * 4 * 4)).write(to: url)
        var settings = TextureImportSettings()
        settings.generateMipmaps = true
        settings.mipLevelCount = 3
        settings.sampler.minFilter = .linear
        settings.sampler.magFilter = .linear
        settings.sampler.addressModeU = .repeat
        settings.sampler.addressModeV = .mirroredRepeat
        settings.sampler.lodMaxClamp = 2
        try settings.encoded().write(to: TextureImportSettings.sidecarURL(for: url))

        let image = try Image(contentsOf: url)
        #expect(image.importedTextureData?.faces[0].map(\.width) == [8, 4, 2])
        let resource = try await AssetsManager.load(Texture2D.self, at: url.path)
        #expect(resource.asset.width == 8)
        #expect(resource.asset.mipmapLevelCount == 3)
        #expect(resource.asset.sampler.descriptor == settings.sampler)
        #expect(image.importedTextureData?.descriptor.pixelFormat == .bgra8_srgb)
    }

    @Test
    func colorAndDataUseDifferentMipAverages() throws {
        let source = Image(width: 2, height: 1, data: Data([0, 0, 0, 0, 255, 255, 255, 255]))
        var settings = TextureImportSettings()
        settings.generateMipmaps = true
        let color = try settings.prepare(source)
        settings.purpose = .data
        let data = try settings.prepare(source)
        #expect(color.faces[0][1].data[0] == 188)
        #expect(color.faces[0][1].data[3] == 128)
        #expect(data.faces[0][1].data[0] == 128)
        #expect(data.descriptor.pixelFormat == .rgba8)
    }

    @Test
    func normalMipmapsRenormalizeVectors() throws {
        var settings = TextureImportSettings()
        settings.purpose = .normal
        settings.generateMipmaps = true
        let source = Image(width: 2, height: 1, data: Data([255, 128, 128, 255, 128, 255, 128, 255]))
        let mip = try settings.prepare(source).faces[0][1]
        let x = Float(mip.data[0]) / 127.5 - 1
        let y = Float(mip.data[1]) / 127.5 - 1
        let z = Float(mip.data[2]) / 127.5 - 1
        #expect(abs((x * x + y * y + z * z).squareRoot() - 1) < 0.02)
    }

    @Test
    func validatesLODCountsColorSpaceAndCubeLayout() throws {
        let image = Image(width: 8, height: 4)
        var settings = TextureImportSettings()
        settings.sampler.lodMinClamp = 3
        settings.sampler.lodMaxClamp = 2
        #expect(throws: TextureImportSettings.ImportError.self) { try settings.validate(for: image) }
        settings = TextureImportSettings()
        settings.mipLevelCount = 5
        #expect(throws: TextureImportSettings.ImportError.self) { try settings.validate(for: image) }
        settings.mipLevelCount = 0
        settings.purpose = .normal
        settings.colorSpace = .sRGB
        #expect(throws: TextureImportSettings.ImportError.self) { try settings.validate(for: image) }
        settings.colorSpace = .linear
        settings.dimension = .cube
        #expect(throws: TextureImportSettings.ImportError.self) { try settings.validate(for: image) }
    }

    @Test
    func cubeSeparatesAllFacesAndTheirMipLevels() throws {
        var settings = TextureImportSettings()
        settings.dimension = .cube
        settings.colorSpace = .linear
        settings.generateMipmaps = true
        let prepared = try settings.prepare(cubeStrip())
        #expect(prepared.faces.count == 6)
        #expect(prepared.faces.allSatisfy { $0.map(\.width) == [4, 2, 1] })
        for face in 0..<6 { #expect(prepared.faces[face][2].data[0] == UInt8(face * 40)) }
        #expect(prepared.descriptor.textureType == .textureCube)
        #expect(prepared.descriptor.subresources.count == 17)
    }

    #if canImport(Metal)
        @Test
        func metalInitializesEveryCubeFaceAndMipLevel() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            var settings = TextureImportSettings()
            settings.dimension = .cube
            settings.generateMipmaps = true
            let prepared = try settings.prepare(cubeStrip())
            let gpu = MetalGPUTexture(descriptor: prepared.descriptor, device: device)
            #expect(gpu.texture.textureType == .typeCube)
            #expect(gpu.texture.pixelFormat == .bgra8Unorm_srgb)
            #expect(gpu.texture.mipmapLevelCount == 3)
            for face in 0..<6 {
                for level in 0..<3 {
                    let expected = prepared.faces[face][level]
                    var bytes = [UInt8](repeating: 0, count: expected.data.count)
                    bytes.withUnsafeMutableBytes { buffer in
                        if let address = buffer.baseAddress {
                            gpu.texture.getBytes(
                                address,
                                bytesPerRow: expected.width * 4,
                                bytesPerImage: expected.data.count,
                                from: MTLRegionMake2D(0, 0, expected.width, expected.height),
                                mipmapLevel: level,
                                slice: face
                            )
                        }
                    }
                    #expect(Data(bytes) == expected.data)
                }
            }
        }
    #endif

    private func cubeStrip() -> Image {
        var bytes = [UInt8]()
        for _ in 0..<4 {
            for face in 0..<6 {
                for _ in 0..<4 { bytes.append(contentsOf: [UInt8(face * 40), 20, 30, 255]) }
            }
        }
        return Image(width: 24, height: 4, data: Data(bytes))
    }
}
