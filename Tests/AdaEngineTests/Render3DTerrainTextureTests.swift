#if os(macOS) || os(Windows) || os(Linux)
    @_spi(Internal) @testable import AdaRender
    import AdaUtils
    import Foundation
    import Math
    import Testing

    #if canImport(Metal)
        import Metal
    #endif
    #if canImport(WebGPU)
        @unsafe @preconcurrency import WebGPU
    #endif

    extension Render3DGPUTests {
        @Suite("Terrain texture arrays", .enabled(if: GoldenFrame.isEnabled))
        @MainActor
        struct TerrainTextureArrays {
            @Test("Array allocation and sampled pixels honor 32 slices and a single-slice array view")
            func terrainTextureArrayCapacityAndPixels() async throws {
                let requested: RenderBackendType = GoldenFrame.activeBackend == .webgpu ? .webgpu : .metal
                unsafe RenderEngine.configurations.preferredBackend = requested
                try RenderEngine.setupRenderEngine()
                let engine = try #require(unsafe RenderEngine.shared)
                try #require(engine.type == requested)
                let device = engine.renderDevice
                for count in [32, 1] {
                    var descriptor = TextureDescriptor(
                        width: 1,
                        height: 1,
                        pixelFormat: .rgba8,
                        textureUsage: [.read],
                        textureType: .texture2DArray,
                        mipmapLevel: 1
                    )
                    descriptor.arrayLength = count
                    let empty = Texture2D(descriptor: descriptor)
                    // Fail safely on the missing allocation before attempting out-of-range slice uploads.
                    if requested == .webgpu {
                        #if canImport(WebGPU)
                            let native = try #require(empty.gpuTexture as? WGPUGPUTexture)
                            try #require(Int(native.texture.depthOrArrayLayers) == count)
                        #else
                            Issue.record("WebGPU must be compiled for this explicitly selected backend")
                            return
                        #endif
                    } else {
                        #if canImport(Metal)
                            let native = try #require(MetalInterop.texture(empty))
                            try #require(native.arrayLength == count)
                        #else
                            Issue.record("Metal must be compiled for this explicitly selected backend")
                            return
                        #endif
                    }
                    descriptor.subresources = (0..<count).map { slice in
                        let color: Color = slice == 0 ? .red : (slice == count - 1 ? .blue : .green)
                        return .init(image: Image(width: 1, height: 1, color: color, format: .rgba8), mipLevel: 0, slice: slice)
                    }
                    let array = Texture2D(descriptor: descriptor)
                    let image = try await sample(array, count: count, device: device)
                    #expect(image.getPixel(x: 0, y: 0) == .red)
                    #expect(image.getPixel(x: 3, y: 1) == (count == 1 ? .red : .blue))
                }
            }

            private func sample(_ array: Texture2D, count: Int, device: RenderDevice) async throws -> Image {
                let source = try ShaderSource(
                    source: """
                        #version 450 core
                        #pragma stage : vert
                        [[main]]
                        void terrain_array_vertex() {
                            vec2 p[3] = vec2[](vec2(-1,-1), vec2(3,-1), vec2(-1,3));
                            gl_Position = vec4(p[gl_VertexIndex], 0, 1);
                        }
                        #version 450 core
                        #pragma stage : frag
                        layout(binding=0) uniform texture2DArray u_Array;
                        layout(binding=1) uniform sampler u_ArraySampler;
                        layout(location=0) out vec4 o_Color;
                        [[main]]
                        void terrain_array_fragment() {
                            float layer = gl_FragCoord.x < 2.0 ? 0.0 : \(count - 1).0;
                            o_Color = texture(sampler2DArray(u_Array, u_ArraySampler), vec3(0.5, 0.5, layer));
                        }
                        """
                )
                let module = try ShaderCompiler(shaderSource: source).compileShaderModule()
                let pipeline = device.createRenderPipeline(
                    from: RenderPipelineDescriptor(
                        vertex: try #require(module.getShader(for: .vertex)),
                        fragment: module.getShader(for: .fragment),
                        debugName: "Terrain array slice pixels",
                        backfaceCulling: false,
                        depthPixelFormat: .none,
                        colorAttachments: [.init(format: .bgra8)]
                    )
                )
                let target = RenderTexture(size: [4, 2], scaleFactor: 1, format: .bgra8)
                let command = device.createCommandQueue().makeCommandBuffer()
                let pass = command.beginRenderPass(
                    .init(colorAttachments: [
                        .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)
                    ])
                )
                pass.setViewport(Rect(x: 0, y: 0, width: 4, height: 2))
                pass.setRenderPipelineState(pipeline)
                pass.setFragmentTexture(array, slot: 0)
                pass.setFragmentSamplerState(array.sampler, slot: 1)
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                pass.endRenderPass()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    command.addCompletedHandler { continuation.resume() }
                    command.commit()
                }
                return try #require(try await device.readImage(from: target))
            }
        }
    }
#endif
