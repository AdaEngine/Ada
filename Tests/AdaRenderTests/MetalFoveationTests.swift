#if os(macOS) && SAGA_METAL_NATIVE_PASS
@_spi(Internal) @testable import AdaRender
import Math
import Metal
import Testing

@Suite("SAGA Metal foveation")
@MainActor
struct SAGAMetalFoveationTests {
    @Test("A single-layer rate map resolves all G-buffers and depth", .enabled(if: metalSupportsRateMapLayers(1)))
    func resolvesSingleLayerGeometry() async throws {
        try await resolvesGeometry(layer: 0, layers: 1)
    }

    @Test("Each eye's rate map resolves all G-buffers and depth", .enabled(if: metalSupportsRateMapLayers(2)), arguments: [0, 1])
    func resolvesEachLayerGeometry(layer: Int) async throws {
        try await resolvesGeometry(layer: layer, layers: 2)
    }

    private func resolvesGeometry(layer: Int, layers: Int) async throws {
        let backend = try SAGAMetalRenderBackend()
        let device = backend.renderDevice
        let metal = try #require(MTLCreateSystemDefaultDevice())
        try #require(metal.supportsRasterizationRateMap(layerCount: layers))
        let screen = MTLSize(width: 128, height: 96, depth: 1)
        func makeMap(swapped: Bool) throws -> any MTLRasterizationRateMap {
            let descriptor = MTLRasterizationRateMapDescriptor(screenSize: screen)
            for index in 0..<layers {
                let horizontal = (index == 0) != swapped ? [Float(0.25), 0.5, 1.0, 0.5] : [1.0, 0.5, 0.25, 0.5]
                let vertical: [Float] = swapped ? [0.25, 0.75, 0.25, 0.25] : [0.5, 1.0, 0.5, 0.25]
                descriptor.setLayer(MTLRasterizationRateLayerDescriptor(horizontal: horizontal, vertical: vertical), at: index)
            }
            return try #require(metal.makeRasterizationRateMap(descriptor: descriptor))
        }

        let vertex = Shader(source: Self.shader, entryPoint: "geometryVertex", stage: .vertex)
        let fragment = Shader(source: Self.shader, entryPoint: "geometryFragment", stage: .fragment)
        vertex.compiledShader = try device.compileShader(from: vertex)
        fragment.compiledShader = try device.compileShader(from: fragment)
        let pipeline = device.createRenderPipeline(from: .init(
            vertex: vertex, fragment: fragment, debugName: "Foveated half-float geometry",
            backfaceCulling: false, depthStencilDescriptor: .init(isDepthWriteEnabled: true, depthCompareOperator: .always),
            depthPixelFormat: .depth_32f, colorAttachments: (0..<4).map { _ in .init(format: .rgba_16f) }
        ))
        func texture(_ format: PixelFormat) -> Texture2D {
            Texture2D(
                gpuTexture: device.createTexture(from: .init(
                    width: screen.width, height: screen.height, pixelFormat: format,
                    textureUsage: [.renderTarget, .read], textureType: .texture2D
                )),
                sampler: device.createSampler(from: .init()),
                size: SizeInt(width: screen.width, height: screen.height)
            )
        }
        let colors = (0..<4).map { _ in texture(.rgba_16f) }
        let depth = texture(.depth_32f)
        let descriptor = RenderPassDescriptor(
            colorAttachments: colors.map { .init(texture: $0, operation: .init(loadAction: .clear, storeAction: .store)) },
            depthStencilAttachment: .init(texture: depth, depthOperation: .init(loadAction: .clear, storeAction: .store))
        )
        let colorRow = screen.width * 8
        let depthRow = screen.width * 4
        let colorSize = colorRow * screen.height
        let depthOffset = colorSize * colors.count
        let depthSize = depthRow * screen.height
        let staging = device.createBuffer(label: "Foveated readback", length: depthOffset + depthSize, options: .storageShared)
        var previous: MetalRasterizationRateMap?
        // A new frame must use the new mapping even when target sizes permit cache reuse.
        for swapped in [false, true] {
            let nativeMap = try makeMap(swapped: swapped)
            let map = try MetalRasterizationRateMap(map: nativeMap, layer: layer, previous: previous)
            previous = map
            #expect(map.screenSize == SizeInt(width: 128, height: 96))
            #expect(nativeMap.physicalSize(layer: layer).width < screen.width)
            let commands = device.createCommandQueue().makeCommandBuffer()
            let pass = try commands.beginFoveatedRenderPass(descriptor, rateMap: map)
            pass.encoder.setRenderPipelineState(pipeline)
            pass.encoder.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.encoder.endRenderPass()
            try pass.resolve()
            commands.commit()
            try await MetalInterop.submitSAGAMetalPass(
                on: device, label: "Read half-float geometry", textures: (colors + [depth]).map { .init($0) },
                buffers: [.init(staging, access: .write)]
            ) { commands, textures, buffers in
                let buffer = try #require(buffers.first)
                let blit = try #require(commands.makeBlitCommandEncoder())
                for (index, texture) in textures.enumerated() {
                    let isDepth = index == colors.count
                    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: screen, to: buffer,
                              destinationOffset: isDepth ? depthOffset : index * colorSize,
                              destinationBytesPerRow: isDepth ? depthRow : colorRow,
                              destinationBytesPerImage: isDepth ? depthSize : colorSize)
                }
                blit.endEncoding()
            }
            let bytes = try await staging.readData()
            func colorComponent(_ offset: Int) -> Float {
                let bits = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
                return Float(Float16(bitPattern: UInt16(littleEndian: bits)))
            }
            for y in [8, 48, 88] {
                for x in [8, 32, 64, 96, 120] {
                    let expectedX = Float(x) / 128
                    let expectedY = Float(y) / 96
                    for index in colors.indices {
                        let offset = index * colorSize + y * colorRow + x * 8
                        #expect(abs(colorComponent(offset) - expectedX) < 0.05)
                        #expect(abs(colorComponent(offset + 2) - expectedY) < 0.05)
                        #expect(abs(colorComponent(offset + 4) - Float(index + 1) / 4) < 0.001)
                    }
                    let depthBits = bytes.withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: depthOffset + y * depthRow + x * 4, as: UInt32.self)
                    }
                    #expect(abs(Float(bitPattern: UInt32(littleEndian: depthBits)) - (0.2 + expectedX * 0.6)) < 0.04)
                }
            }
        }
    }

    @Test("Out-of-range rate map layers fail before encoding", .enabled(if: metalSupportsRateMapLayers(1)))
    func rejectsInvalidLayer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSize(width: 1, height: 1, depth: 1))
        let descriptor = MTLRasterizationRateMapDescriptor(screenSize: MTLSize(width: 32, height: 32, depth: 1), layer: layer)
        let map = try #require(device.makeRasterizationRateMap(descriptor: descriptor))
        #expect(throws: FoveatedRenderingError.self) { try MetalRasterizationRateMap(map: map, layer: -1) }
        #expect(throws: FoveatedRenderingError.self) { try MetalRasterizationRateMap(map: map, layer: 1) }
    }

    private static let shader = """
        struct VertexOut {
            @builtin(position) position: vec4f,
            @location(0) uv: vec2f,
        }
        @vertex fn geometryVertex(@builtin(vertex_index) id: u32) -> VertexOut {
            let uv = vec2f(f32((id << 1u) & 2u), f32(id & 2u));
            return VertexOut(vec4f(uv * vec2f(2, -2) + vec2f(-1, 1), 0, 1), uv);
        }
        struct FragmentOut {
            @location(0) c0: vec4f,
            @location(1) c1: vec4f,
            @location(2) c2: vec4f,
            @location(3) c3: vec4f,
            @builtin(frag_depth) depth: f32,
        }
        @fragment fn geometryFragment(input: VertexOut) -> FragmentOut {
            return FragmentOut(vec4f(input.uv, 0.25, 1), vec4f(input.uv, 0.5, 1),
                vec4f(input.uv, 0.75, 1), vec4f(input.uv, 1, 1), 0.2 + 0.6 * input.uv.x);
        }
        """
}
#endif
