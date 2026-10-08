#if canImport(Metal)
@_spi(Internal) @testable import AdaRender
@testable import AdaText
import AdaUtils
import CoreGraphics
import Foundation
import ImageIO
import Math
@preconcurrency import Metal
import Testing

@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct TextShaderRenderingTests {
    init() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
    }

    @Test(arguments: [Float(1), 0.5])
    func antialiasedEdgeAppliesCoverageAndOpacityOnce(_ opacity: Float) async throws {
        let renderer = try TextShaderProbe()
        let foreground = Color(0.8, 0.6, 0.4, opacity)
        let vertices = renderer.quad(
            rect: Rect(x: 0, y: 0, width: 32, height: 32),
            uv: [0, 0, 1, 1],
            foreground: foreground,
            // A transparent colored outline must not tint the edge.
            outline: Color(0, 0, 1, 0),
            outputSize: Size(width: 32, height: 32)
        )
        let atlas = [Float](repeating: 0.5, count: 4)
        let pixels = try await renderer.render(
            vertices: vertices,
            atlas: atlas.withUnsafeBytes { Data($0) },
            atlasSize: SizeInt(width: 1, height: 1),
            outputSize: SizeInt(width: 32, height: 32)
        )
        let pixel = Array(pixels[(16 * 32 + 16) * 4..<(16 * 32 + 16) * 4 + 4])
        let coverage: Float = 0.5
        for (channel, value) in zip(pixel.prefix(3), [foreground.blue, foreground.green, foreground.red]) {
            #expect(abs(Float(channel) / 255 - value * coverage * opacity) < 0.01)
        }
    }

    @Test
    func translucentFillCompositesOverOutline() async throws {
        let renderer = try TextShaderProbe()
        let vertices = renderer.quad(
            rect: Rect(x: 0, y: 0, width: 32, height: 32),
            uv: [0, 0, 1, 1],
            foreground: Color(1, 0, 0, 0.5),
            outline: .blue,
            outlineWidth: 1,
            outputSize: Size(width: 32, height: 32)
        )
        let atlas = [Float](repeating: 0.5, count: 4)
        let pixels = try await renderer.render(
            vertices: vertices,
            atlas: atlas.withUnsafeBytes { Data($0) },
            atlasSize: SizeInt(width: 1, height: 1),
            outputSize: SizeInt(width: 32, height: 32)
        )
        let offset = (16 * 32 + 16) * 4
        #expect(abs(Float(pixels[offset]) / 255 - 0.75) < 0.01)
        #expect(abs(Float(pixels[offset + 2]) / 255 - 0.25) < 0.01)
    }

    @Test
    func shaderDistanceRangeMatchesFontAtlas() async throws {
        let renderer = try TextShaderProbe()
        let vertices = renderer.quad(
            rect: Rect(x: 0, y: 0, width: 32, height: 32),
            uv: [0, 0, 1, 1],
            foreground: .white,
            outputSize: Size(width: 32, height: 32)
        )
        // One atlas texel per screen pixel, 0.25 px inside the contour.
        let distance = Float(0.5 + 0.25 / FontAtlasGenerator.atlasPixelRange)
        let atlas = [Float](repeating: distance, count: 32 * 32 * 4)
        let pixels = try await renderer.render(
            vertices: vertices,
            atlas: atlas.withUnsafeBytes { Data($0) },
            atlasSize: SizeInt(width: 32, height: 32),
            outputSize: SizeInt(width: 32, height: 32)
        )
        #expect(abs(Float(pixels[(16 * 32 + 16) * 4]) / 255 - 0.75) < 0.01)
    }

    @Test
    func regularFontRendersAtEditorSizes() async throws {
        let renderer = try TextShaderProbe()
        let outputSize = SizeInt(width: 1000, height: 300)
        var vertices: [GlyphVertexData] = []
        var atlas: Texture2D?
        for (row, pointSize) in [Double(11), 12, 14, 17].enumerated() {
            var attributes = TextAttributeContainer()
            attributes.font = .system(size: pointSize * 2)
            attributes.foregroundColor = Color(139 / 255, 145 / 255, 155 / 255, 1)
            let manager = TextLayoutManager()
            manager.setTextContainer(TextContainer(
                text: AttributedText("Regular \(Int(pointSize)) pt  •  Position  Rotation  Scale  012345", attributes: attributes),
                textAlignment: .leading,
                lineBreakMode: .byWordWrapping
            ))
            manager.fitToSize(.infinity)
            for glyph in manager.textLines.flatMap({ $0.flatMap { Array($0) } }) {
                atlas = glyph.textureAtlas
                vertices += renderer.quad(
                    rect: Rect(
                        x: 24 + glyph.position.x,
                        y: Float(48 + row * 66) - glyph.position.w,
                        width: glyph.position.z - glyph.position.x,
                        height: glyph.position.w - glyph.position.y
                    ),
                    uv: glyph.textureCoordinates,
                    foreground: attributes.foregroundColor,
                    outputSize: Size(width: 1000, height: 300)
                )
            }
        }
        let fontAtlas = try #require(atlas)
        let pixels = try await renderer.render(
            vertices: vertices,
            atlas: fontAtlas.image.data,
            atlasSize: fontAtlas.size,
            outputSize: outputSize,
            background: MTLClearColor(red: 24 / 255, green: 25 / 255, blue: 29 / 255, alpha: 1)
        )
        #expect(pixels.filter { $0 > 80 && $0 < 200 }.count > 1000)
        if let outputPath = ProcessInfo.processInfo.environment["ADA_TEXT_RENDER_OUTPUT"] {
            try renderer.writePNG(pixels, size: outputSize, to: URL(fileURLWithPath: outputPath))
        }
    }
}

@MainActor
private final class TextShaderProbe {
    let device: MTLDevice
    let pipeline: MetalRenderPipeline

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shaderURL = ProcessInfo.processInfo.environment["ADA_TEXT_SHADER_SOURCE"].map { URL(fileURLWithPath: $0) }
            ?? repository.appendingPathComponent("Sources/AdaText/Assets/text.glsl")
        let compiler = try ShaderCompiler(from: shaderURL)
        var descriptor = TextPipeline().configurate(with: RenderPipelineEmptyConfiguration())
        descriptor.vertex = try Self.compile(.vertex, compiler: compiler, device: device)
        descriptor.fragment = try Self.compile(.fragment, compiler: compiler, device: device)
        pipeline = try MetalRenderPipeline(descriptor: descriptor, device: device)
    }

    private static func compile(_ stage: ShaderStage, compiler: ShaderCompiler, device: MTLDevice) throws -> Shader {
        let spirv = try compiler.compileSpirvBin(for: stage, ignoreCache: true)
        let compiled = try SpirvCompiler(spriv: spirv.data, stage: stage, deviceLang: .msl).compile()
        let shader = Shader(
            source: compiled.source,
            entryPoint: try #require(compiled.entryPoints.first?.name),
            stage: stage,
            reflectionData: compiled.reflection
        )
        shader.compiledShader = try MetalShader(shader: shader, device: device)
        return shader
    }

    func quad(
        rect: Rect,
        uv: Vector4,
        foreground: Color,
        outline: Color = .clear,
        outlineWidth: Float = 0,
        outputSize: Size
    ) -> [GlyphVertexData] {
        let points: [(Float, Float, Float, Float)] = [
            (rect.minX, rect.minY, uv.x, uv.w), (rect.maxX, rect.minY, uv.z, uv.w),
            (rect.maxX, rect.maxY, uv.z, uv.y), (rect.minX, rect.minY, uv.x, uv.w),
            (rect.maxX, rect.maxY, uv.z, uv.y), (rect.minX, rect.maxY, uv.x, uv.y)
        ]
        return points.map { x, y, u, v in
            GlyphVertexData(
                position: [2 * x / outputSize.width - 1, 1 - 2 * y / outputSize.height, 0, 1],
                foregroundColor: foreground,
                outlineColor: outline,
                outlineWidth: outlineWidth,
                textureCoordinate: [u, v],
                textureIndex: 0
            )
        }
    }

    func render(
        vertices: [GlyphVertexData],
        atlas: Data,
        atlasSize: SizeInt,
        outputSize: SizeInt,
        background: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    ) async throws -> [UInt8] {
        let texture = try makeAtlas(atlas, size: atlasSize)
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: outputSize.width, height: outputSize.height, mipmapped: false
        )
        targetDescriptor.storageMode = .shared
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        let target = try #require(device.makeTexture(descriptor: targetDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = background
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline.renderPipeline)
        let vertexBuffer = try vertices.withUnsafeBytes { bytes in
            let address = try #require(bytes.baseAddress)
            return try #require(device.makeBuffer(bytes: address, length: bytes.count))
        }
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        let transforms = [Transform3D.identity, .identity, .identity]
        transforms.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress {
                encoder.setVertexBytes(address, length: bytes.count, index: 2)
            }
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(device.makeSamplerState(descriptor: samplerDescriptor), index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        #expect(command.status == .completed)
        var pixels = [UInt8](repeating: 0, count: outputSize.width * outputSize.height * 4)
        target.getBytes(
            &pixels,
            bytesPerRow: outputSize.width * 4,
            from: MTLRegionMake2D(0, 0, outputSize.width, outputSize.height),
            mipmapLevel: 0
        )
        return pixels
    }

    private func makeAtlas(_ data: Data, size: SizeInt) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: size.width, height: size.height, mipmapped: false
        )
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        try data.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, size.width, size.height),
                mipmapLevel: 0,
                withBytes: try #require(bytes.baseAddress),
                bytesPerRow: size.width * 16
            )
        }
        return texture
    }

    func writePNG(_ pixels: [UInt8], size: SizeInt, to url: URL) throws {
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let image = try #require(CGImage(
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
#endif
