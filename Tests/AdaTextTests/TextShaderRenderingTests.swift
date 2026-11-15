#if os(macOS) && SAGA_METAL_NATIVE_PASS
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
            let validatesSAGA = ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_WGSL"] == "1"
            unsafe RenderEngine.configurations.preferredBackend = validatesSAGA ? .saga : .headless
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
            fontAtlas: fontAtlas,
            outputSize: outputSize,
            background: Color(red: 24 / 255, green: 25 / 255, blue: 29 / 255, alpha: 1)
        )
        #expect(pixels.filter { $0 > 80 && $0 < 200 }.count > 1000)
        if let outputPath = ProcessInfo.processInfo.environment["ADA_TEXT_RENDER_OUTPUT"] {
            try renderer.writePNG(pixels, size: outputSize, to: URL(fileURLWithPath: outputPath))
        }
    }
}

@MainActor
private final class TextShaderProbe {
    let device: SAGARenderDevice
    let pipeline: any RenderPipeline

    init() throws {
        if let active = unsafe RenderEngine.shared?.renderDevice as? SAGARenderDevice {
            device = active
        } else {
            let backend = try SAGAMetalRenderBackend()
            device = try #require(backend.renderDevice as? SAGARenderDevice)
        }
        let repository = ProcessInfo.processInfo.environment["ADAENGINE_SHADER_SOURCE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shaderURL = ProcessInfo.processInfo.environment["ADA_TEXT_SHADER_SOURCE"].map { URL(fileURLWithPath: $0) }
            ?? repository.appendingPathComponent("Sources/AdaText/Assets/text.wesl")
        let source = try ShaderModule.linkWESL(from: shaderURL)
        let module = try ShaderModule.createModule(from: source, device: device)
        var descriptor = TextPipeline().configurate(with: RenderPipelineEmptyConfiguration())
        descriptor.vertex = try #require(module.getShader(for: .vertex))
        descriptor.fragment = try #require(module.getShader(for: .fragment))
        pipeline = device.createRenderPipeline(from: descriptor)
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
        fontAtlas: Texture2D,
        outputSize: SizeInt,
        background: Color
    ) async throws -> [UInt8] {
        if let texture = fontAtlas.gpuTexture as? SAGAGPUTexture, texture.context === device.context {
            return try await render(vertices: vertices, texture: fontAtlas, outputSize: outputSize, background: background)
        }
        return try await render(
            vertices: vertices, atlas: fontAtlas.image.data, atlasSize: fontAtlas.size,
            atlasFormat: fontAtlas.subresourcePixelFormat, outputSize: outputSize, background: background
        )
    }

    func render(
        vertices: [GlyphVertexData],
        atlas: Data,
        atlasSize: SizeInt,
        atlasFormat: PixelFormat = .rgba_32f,
        outputSize: SizeInt,
        background: Color = .black
    ) async throws -> [UInt8] {
        try #require(atlasFormat == .rgba_16f || atlasFormat == .rgba_32f)
        let rowBytes = atlasSize.width * (atlasFormat == .rgba_16f ? 8 : 16)
        try #require(atlas.count == rowBytes * atlasSize.height)
        let texture = Texture2D(
            gpuTexture: device.createTexture(from: .init(
                width: atlasSize.width, height: atlasSize.height, pixelFormat: atlasFormat,
                textureUsage: [.read], textureType: .texture2D
            )),
            sampler: device.createSampler(from: .init(minFilter: .linear, magFilter: .linear)),
            size: atlasSize
        )
        try unsafe atlas.withUnsafeBytes { bytes in
            let address = try #require(unsafe bytes.baseAddress)
            unsafe texture.gpuTexture.replaceRegion(
                RectInt(x: 0, y: 0, width: atlasSize.width, height: atlasSize.height),
                mipmapLevel: 0, withBytes: address, bytesPerRow: rowBytes
            )
        }
        return try await render(vertices: vertices, texture: texture, outputSize: outputSize, background: background)
    }

    private func render(
        vertices: [GlyphVertexData], texture: Texture2D, outputSize: SizeInt, background: Color
    ) async throws -> [UInt8] {
        let errorsBefore = device.context.errorLog.all.count
        let target = Texture2D(
            gpuTexture: device.createTexture(from: .init(
                width: outputSize.width, height: outputSize.height, pixelFormat: .bgra8,
                textureUsage: [.renderTarget, .read], textureType: .texture2D
            )),
            sampler: device.createSampler(from: .init()), size: outputSize
        )
        var vertexData = BufferData(label: "Text shader probe vertices", elements: vertices)
        vertexData.write(to: device)
        let command = device.createCommandQueue().makeCommandBuffer()
        let encoder = command.beginRenderPass(.init(colorAttachments: [
            .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: background)
        ]))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexData, offset: 0, slot: 0)
        let view = GlobalViewUniform(projectionMatrix: .identity, viewProjectionMatrix: .identity)
        encoder.setVertexBuffer(view, slot: GlobalBufferIndex.viewUniform)
        encoder.setResourceSet(.init(bindings: [
            .init(binding: 0, shaderStages: .fragment, resource: .texture(texture)),
            .init(binding: 1, shaderStages: .fragment, resource: .sampler(texture.sampler)),
        ]), index: 0)
        encoder.draw(type: .triangle, vertexStart: 0, vertexCount: vertices.count, instanceCount: 1)
        encoder.endRenderPass()
        command.commit()
        let image = try #require(try await device.readImage(from: target))
        #expect(device.context.errorLog.all.count == errorsBefore, "\(device.context.errorLog.all)")
        return Array(image.data)
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
