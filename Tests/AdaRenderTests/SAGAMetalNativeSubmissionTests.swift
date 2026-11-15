#if SAGA_METAL_NATIVE_PASS && os(macOS)
@_spi(Internal) @testable import AdaRender
import AdaUtils
import Foundation
import Metal
import Testing

func metalSupportsRateMapLayers(_ count: Int) -> Bool {
    MTLCreateSystemDefaultDevice()?.supportsRasterizationRateMap(layerCount: count) == true
}

@MainActor
struct SAGAMetalNativeSubmissionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_WGSL"] == "1"))
    func platformPassReadsEarlierRendererWorkAndReportsCommit() async throws {
        try RenderEngine.setupRenderEngine()
        let renderer = try #require(unsafe RenderEngine.shared)
        try #require(renderer.type == .saga)
        let device = renderer.renderDevice
        let source = RenderTexture(size: [2, 2], scaleFactor: 1, format: .rgba8)
        let destination = RenderTexture(size: [2, 2], scaleFactor: 1, format: .rgba8)
        let vertices = device.createVertexBuffer(label: "Platform geometry", length: 16, binding: 0)
        let commands = device.createCommandQueue().makeCommandBuffer()
        let earlierPass = commands.beginRenderPass(.init(colorAttachments: [
            .init(texture: source, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .red)
        ]))
        earlierPass.endRenderPass()
        commands.commit()

        var events: [String] = []
        try await MetalInterop.submitSAGAMetalPass(
            on: device, label: "Read previous pass",
            textures: [.init(source), .init(destination, access: .write)], buffers: [.init(vertices)],
            onCommitted: { events.append("committed") }
        ) { commandBuffer, textures, buffers in
            try #require(textures.count == 2)
            #expect(buffers.first?.length == 16)
            events.append("recorded")
            let blit = try #require(commandBuffer.makeBlitCommandEncoder())
            let origin = MTLOrigin(x: 0, y: 0, z: 0)
            blit.copy(from: textures[0], sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin,
                      sourceSize: MTLSize(width: 2, height: 2, depth: 1), to: textures[1],
                      destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
            blit.endEncoding()
        }
        #expect(events == ["recorded", "committed"])
        let image = try #require(try await device.readImage(from: destination))
        let pixel = image.getPixel(x: 1, y: 1)
        #expect(pixel.red > 0.99 && pixel.green < 0.01 && pixel.blue < 0.01)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_WGSL"] == "1" && metalSupportsRateMapLayers(1)))
    func resolvesSingleLayerFoveatedGeometry() async throws {
        try await resolvesFoveatedGeometryFromSAGAToLogicalCoordinates(layer: 0, layers: 1, colorCount: 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_WGSL"] == "1" && metalSupportsRateMapLayers(2)),
          arguments: [0, 1])
    func resolvesEachLayerOfFoveatedGeometry(layer: Int) async throws {
        try await resolvesFoveatedGeometryFromSAGAToLogicalCoordinates(layer: layer, layers: 2, colorCount: 6)
    }

    private func resolvesFoveatedGeometryFromSAGAToLogicalCoordinates(layer: Int, layers: Int, colorCount: Int) async throws {
        try RenderEngine.setupRenderEngine()
        let renderer = try #require(unsafe RenderEngine.shared)
        try #require(renderer.type == .saga)
        let device = renderer.renderDevice
        let metal = try #require(MTLCreateSystemDefaultDevice())
        try #require(metal.supportsRasterizationRateMap(layerCount: layers))
        let extent = MTLSize(width: 64, height: 64, depth: 1)
        let descriptor = MTLRasterizationRateMapDescriptor(screenSize: extent)
        for index in 0..<layers {
            descriptor.setLayer(MTLRasterizationRateLayerDescriptor(
                horizontal: index == 0 ? [0.25, 0.5, 1, 0.5] : [1, 0.5, 0.5, 0.25],
                vertical: [0.5, 1, 0.5, 0.25]), at: index)
        }
        let native = try #require(metal.makeRasterizationRateMap(descriptor: descriptor))
        let map = try MetalInterop.rasterizationRateMap(native, layer: layer)
        let channelValues = (1...colorCount).map { Float($0) / Float(colorCount + 1) }
        let colors = channelValues.map { _ in RenderTexture(size: [64, 64], scaleFactor: 1, format: .rgba8) }
        let fields = colors.indices.map { "@location(\($0)) color\($0): vec4f," }.joined(separator: "\n")
        let values = channelValues.map { "vec4f(input.uv, \($0), 1)" }.joined(separator: ", ")
        let depth = RenderTexture(size: [64, 64], scaleFactor: 1, format: .depth_32f)
        let module = try ShaderModule.createWESL(source: """
            struct VertexOutput {
                @builtin(position) position: vec4f,
                @location(0) uv: vec2f,
            }
            struct Geometry {
                \(fields)
                @builtin(frag_depth) depth: f32,
            }
            @vertex fn vertexMain(@builtin(vertex_index) i: u32) -> VertexOutput {
                let uv = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
                return VertexOutput(vec4f(uv * vec2f(2, -2) + vec2f(-1, 1), 0, 1), uv);
            }
            @fragment fn fragmentMain(input: VertexOutput) -> Geometry {
                return Geometry(\(values), 0.2 + 0.6 * input.uv.x);
            }
            """)
        let vertex = try #require(module.getShader(for: .vertex))
        let pipeline = device.createRenderPipeline(from: RenderPipelineDescriptor(
            vertex: vertex, fragment: module.getShader(for: .fragment),
            debugName: "Foveated geometry regression", backfaceCulling: false,
            depthStencilDescriptor: .init(isDepthWriteEnabled: true, depthCompareOperator: .always),
            depthPixelFormat: .depth_32f,
            colorAttachments: colors.map { _ in .init(format: .rgba8) }
        ))
        let commands = device.createCommandQueue().makeCommandBuffer()
        let pass = try commands.beginFoveatedRenderPass(.init(
            colorAttachments: colors.map { .init(texture: $0, operation: .init(loadAction: .clear, storeAction: .store)) },
            depthStencilAttachment: .init(texture: depth, depthOperation: .init(loadAction: .clear, storeAction: .store))
        ), rateMap: map)
        pass.encoder.setRenderPipelineState(pipeline)
        pass.encoder.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
        pass.encoder.endRenderPass()
        try pass.resolve()
        commands.commit()

        let readback = device.createBuffer(label: "Resolved depth", length: 64 * 64 * 4, options: .storageShared)
        try await MetalInterop.submitSAGAMetalPass(
            on: device, label: "Read foveated depth", textures: [.init(depth)], buffers: [.init(readback, access: .write)]
        ) { commands, textures, buffers in
            let blit = try #require(commands.makeBlitCommandEncoder())
            blit.copy(from: textures[0], sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: extent, to: buffers[0], destinationOffset: 0,
                      destinationBytesPerRow: 256, destinationBytesPerImage: 16_384)
            blit.endEncoding()
        }
        let depthBytes = try await readback.readData()
        for (index, texture) in colors.enumerated() {
            let image = try #require(try await device.readImage(from: texture))
            for x in [8, 32, 56] {
                let pixel = image.getPixel(x: x, y: 32)
                #expect(abs(pixel.red - Float(x) / 64) < 0.06)
                #expect(abs(pixel.green - 0.5) < 0.06)
                #expect(abs(pixel.blue - channelValues[index]) < 0.01)
                let offset = (32 * 64 + x) * 4
                let bits = depthBytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
                #expect(abs(Float(bitPattern: UInt32(littleEndian: bits)) - (0.2 + 0.6 * Float(x) / 64)) < 0.04)
            }
        }
    }
}
#endif
