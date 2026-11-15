import AdaAssets
import Foundation
import Testing

@_spi(Internal) @testable import AdaRender

#if os(macOS) && SAGA_METAL_NATIVE_PASS
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

    #if os(macOS) && SAGA_METAL_NATIVE_PASS
        @Test
        @MainActor
        func sagaMetalInitializesEveryCubeFaceAndMipLevel() async throws {
            let backend = try SAGAMetalRenderBackend()
            let device = backend.renderDevice
            var settings = TextureImportSettings()
            settings.dimension = .cube
            settings.generateMipmaps = true
            let prepared = try settings.prepare(cubeStrip())
            let cube = Texture2D(
                gpuTexture: device.createTexture(from: prepared.descriptor),
                sampler: device.createSampler(from: .init()),
                size: .init(width: prepared.descriptor.width, height: prepared.descriptor.height)
            )
            struct Readback: Sendable {
                let face: Int
                let level: Int
                let image: Image
                let offset: Int
            }
            let rowPitch = 256
            var length = 0
            var readbacks: [Readback] = []
            for face in 0..<6 {
                for level in 0..<3 {
                    let image = prepared.faces[face][level]
                    readbacks.append(Readback(face: face, level: level, image: image, offset: length))
                    length += rowPitch * image.height
                }
            }
            let staging = device.createBuffer(label: "Cube import readback", length: length, options: .storageShared)
            try await MetalInterop.submitSAGAMetalPass(
                on: device, label: "Read imported cube", textures: [.init(cube)], buffers: [.init(staging, access: .write)]
            ) { [readbacks] commands, textures, buffers in
                let nativeTexture = try #require(textures.first)
                let nativeBuffer = try #require(buffers.first)
                // Copy the backing array slices here and sample the cube view below.
                #expect(nativeTexture.arrayLength == 6)
                #expect(nativeTexture.pixelFormat == .bgra8Unorm_srgb)
                #expect(nativeTexture.mipmapLevelCount == 3)
                let blit = try #require(commands.makeBlitCommandEncoder())
                for readback in readbacks {
                    let image = readback.image
                    blit.copy(from: nativeTexture, sourceSlice: readback.face, sourceLevel: readback.level,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: image.width, height: image.height, depth: 1),
                              to: nativeBuffer, destinationOffset: readback.offset, destinationBytesPerRow: rowPitch,
                              destinationBytesPerImage: rowPitch * image.height)
                }
                blit.endEncoding()
            }
            let actual = try await staging.readData()
            for readback in readbacks {
                let image = readback.image
                let rowLength = image.width * 4
                for row in 0..<image.height {
                    let start = readback.offset + row * rowPitch
                    let expected = row * rowLength
                    #expect(actual[start ..< start + rowLength] == image.data[expected ..< expected + rowLength])
                }
            }

            let shader = """
                @group(0) @binding(0) var imported: texture_cube<f32>;
                @group(0) @binding(1) var sourceSampler: sampler;
                @vertex fn vs(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
                    let uv = vec2f(f32((index << 1u) & 2u), f32(index & 2u));
                    return vec4f(uv * vec2f(2, -2) + vec2f(-1, 1), 0, 1);
                }
                @fragment fn fs(@builtin(position) point: vec4f) -> @location(0) vec4f {
                    let directions = array(vec3f(1, 0, 0), vec3f(-1, 0, 0), vec3f(0, 1, 0),
                                           vec3f(0, -1, 0), vec3f(0, 0, 1), vec3f(0, 0, -1));
                    return textureSampleLevel(imported, sourceSampler, directions[u32(point.x)], floor(point.y));
                }
                """
            let vertex = Shader(source: shader, entryPoint: "vs", stage: .vertex)
            let fragment = Shader(source: shader, entryPoint: "fs", stage: .fragment)
            vertex.compiledShader = try device.compileShader(from: vertex)
            fragment.compiledShader = try device.compileShader(from: fragment)
            let pipeline = device.createRenderPipeline(from: .init(
                vertex: vertex, fragment: fragment, debugName: "Sample imported cube",
                backfaceCulling: false, depthPixelFormat: .none, colorAttachments: [.init(format: .rgba8)]
            ))
            let sampled = Texture2D(
                gpuTexture: device.createTexture(from: .init(
                    width: 6, height: 3, pixelFormat: .rgba8, textureUsage: [.renderTarget, .read], textureType: .texture2D
                )), sampler: device.createSampler(from: .init()), size: [6, 3]
            )
            let commands = device.createCommandQueue().makeCommandBuffer()
            let pass = commands.beginRenderPass(.init(colorAttachments: [
                .init(texture: sampled, operation: .init(loadAction: .clear, storeAction: .store))
            ]))
            pass.setRenderPipelineState(pipeline)
            pass.setResourceSet(.init(bindings: [
                .init(binding: 0, shaderStages: .fragment, resource: .texture(cube)),
                .init(binding: 1, shaderStages: .fragment, resource: .sampler(cube.sampler))
            ]), index: 0)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            commands.commit()
            let sampledImage = try #require(try await device.readImage(from: sampled))
            func linear(_ sRGB: Float) -> Float {
                sRGB <= 0.04045 ? sRGB / 12.92 : pow((sRGB + 0.055) / 1.055, 2.4)
            }
            for readback in readbacks {
                let expected = readback.image.data
                let pixel = sampledImage.getPixel(x: readback.face, y: readback.level)
                #expect(abs(pixel.red - linear(Float(expected[2]) / 255)) <= 2.0 / 255)
                #expect(abs(pixel.green - linear(Float(expected[1]) / 255)) <= 2.0 / 255)
                #expect(abs(pixel.blue - linear(Float(expected[0]) / 255)) <= 2.0 / 255)
                #expect(pixel.alpha == Float(expected[3]) / 255)
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
