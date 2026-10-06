#if canImport(Metal)
@_spi(Internal) @testable import AdaRender
import Math
import Metal
import Testing

@Suite("Metal foveation")
struct MetalFoveationTests {
    @Test("Geometry resolves all G-buffers and depth with the selected eye's rate map", arguments: [(0, 1), (0, 2), (1, 2)])
    func resolvesGeometry(layer: Int, layers: Int) async throws {
        let backend = MetalRenderBackend()
        let device = try #require(MetalInterop.commandQueue(for: backend.renderDevice)?.device)
        let queue = try #require(device.makeCommandQueue())
        try #require(device.supportsRasterizationRateMap(layerCount: layers))
        let screen = MTLSize(width: 128, height: 96, depth: 1)
        func makeMap(swapped: Bool) throws -> any MTLRasterizationRateMap {
            let descriptor = MTLRasterizationRateMapDescriptor(screenSize: screen)
            for index in 0..<layers {
                let rate = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSize(width: 4, height: 4, depth: 1))
                for sample in 0..<4 {
                    rate.horizontal[sample] = (index == 0) != swapped ? [0.25, 0.5, 1.0, 0.5][sample] : [1.0, 0.5, 0.25, 0.5][sample]
                    rate.vertical[sample] = swapped ? [0.25, 0.75, 0.25, 0.25][sample] : [0.5, 1.0, 0.5, 0.25][sample]
                }
                descriptor.setLayer(rate, at: index)
            }
            return try #require(device.makeRasterizationRateMap(descriptor: descriptor))
        }
        let library = try await device.makeLibrary(source: Self.shader, options: nil)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "geometryVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "geometryFragment")
        for index in 0..<4 { pipelineDescriptor.colorAttachments[index].pixelFormat = .rgba16Float }
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.inputPrimitiveTopology = .triangle
        let pipeline = try await device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .always
        depthDescriptor.isDepthWriteEnabled = true
        let depthState = try #require(device.makeDepthStencilState(descriptor: depthDescriptor))
        func texture(_ format: MTLPixelFormat) throws -> Texture2D {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: screen.width, height: screen.height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            let native = try #require(device.makeTexture(descriptor: descriptor))
            return Texture2D(
                gpuTexture: MetalGPUTexture(texture: native),
                sampler: backend.renderDevice.createSampler(from: .init()),
                size: SizeInt(width: screen.width, height: screen.height)
            )
        }
        let colors = try (0..<4).map { _ in try texture(.rgba16Float) }
        let depth = try texture(.depth32Float)
        let descriptor = RenderPassDescriptor(
            colorAttachments: colors.map { .init(texture: $0, operation: .init(loadAction: .clear, storeAction: .store)) },
            depthStencilAttachment: .init(texture: depth, depthOperation: .init(loadAction: .clear, storeAction: .store))
        )
        var previous: MetalRasterizationRateMap?
        // A new frame must use the new mapping even when target sizes permit cache reuse.
        for swapped in [false, true] {
            let nativeMap = try makeMap(swapped: swapped)
            let map = try MetalRasterizationRateMap(map: nativeMap, layer: layer, previous: previous)
            previous = map
            #expect(map.screenSize == SizeInt(width: 128, height: 96))
            #expect(nativeMap.physicalSize(layer: layer).width < screen.width)
            let commands = MetalCommandQueue(commandQueue: queue).makeCommandBuffer()
            let pass = try commands.beginFoveatedRenderPass(descriptor, rateMap: map)
            let encoder = try #require(pass.encoder as? MetalRenderCommandEncoder).renderEncoder
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: 128, height: 96, znear: 0, zfar: 1))
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            pass.encoder.endRenderPass()
            try pass.resolve()
            let nativeCommands = try #require(commands as? MetalCommandEncoder).commandBuffer
            let blit = try #require(nativeCommands.makeBlitCommandEncoder())
            func readback(_ texture: Texture2D, bytesPerPixel: Int) throws -> any MTLBuffer {
                let row = screen.width * bytesPerPixel
                let buffer = try #require(device.makeBuffer(length: row * screen.height, options: .storageModeShared))
                blit.copy(
                    from: try #require(MetalInterop.texture(texture)),
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: screen,
                    to: buffer,
                    destinationOffset: 0,
                    destinationBytesPerRow: row,
                    destinationBytesPerImage: row * screen.height
                )
                return buffer
            }
            let colorBuffers = try colors.map { try readback($0, bytesPerPixel: 8) }
            let depthBuffer = try readback(depth, bytesPerPixel: 4)
            blit.endEncoding()
            await withCheckedContinuation { continuation in
                nativeCommands.addCompletedHandler { _ in continuation.resume() }
                commands.commit()
            }
            #expect(nativeCommands.status == .completed)
            for y in [8, 48, 88] {
                for x in [8, 32, 64, 96, 120] {
                    let expectedX = Float(x) / 128
                    let expectedY = Float(y) / 96
                    for (index, buffer) in colorBuffers.enumerated() {
                        let values = unsafe buffer.contents().assumingMemoryBound(to: Float16.self)
                        let offset = (y * 128 + x) * 4
                        #expect(abs(unsafe Float(values[offset]) - expectedX) < 0.05)
                        #expect(abs(unsafe Float(values[offset + 1]) - expectedY) < 0.05)
                        #expect(abs(unsafe Float(values[offset + 2]) - Float(index + 1) / 4) < 0.001)
                    }
                    let depths = unsafe depthBuffer.contents().assumingMemoryBound(to: Float.self)
                    #expect(abs(unsafe depths[y * 128 + x] - (0.2 + expectedX * 0.6)) < 0.04)
                }
            }
        }
    }

    @Test("Out-of-range rate map layers fail before encoding")
    func rejectsInvalidLayer() throws {
        let backend = MetalRenderBackend()
        let device = try #require(MetalInterop.commandQueue(for: backend.renderDevice)?.device)
        let layer = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSize(width: 1, height: 1, depth: 1))
        let descriptor = MTLRasterizationRateMapDescriptor(screenSize: MTLSize(width: 32, height: 32, depth: 1), layer: layer)
        let map = try #require(device.makeRasterizationRateMap(descriptor: descriptor))
        #expect(throws: FoveatedRenderingError.self) { try MetalRasterizationRateMap(map: map, layer: -1) }
        #expect(throws: FoveatedRenderingError.self) { try MetalRasterizationRateMap(map: map, layer: 1) }
    }

    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct VertexOut { float4 position [[position]]; float2 uv; uint layer [[render_target_array_index]]; };
        vertex VertexOut geometryVertex(uint id [[vertex_id]], constant uint &layer [[buffer(30)]]) {
            float2 uv = float2((id << 1) & 2, id & 2);
            return { float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv, layer };
        }
        struct FragmentOut {
            float4 c0 [[color(0)]]; float4 c1 [[color(1)]];
            float4 c2 [[color(2)]]; float4 c3 [[color(3)]]; float depth [[depth(any)]];
        };
        fragment FragmentOut geometryFragment(VertexOut in [[stage_in]]) {
            return { float4(in.uv, 0.25, 1), float4(in.uv, 0.5, 1),
                float4(in.uv, 0.75, 1), float4(in.uv, 1, 1), 0.2 + 0.6 * in.uv.x };
        }
        """
}
#endif
