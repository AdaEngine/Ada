#if os(macOS) || os(Windows) || os(Linux)
    @_spi(Internal) @testable import AdaRender
    import AdaUtils
    import Foundation
    import Math
    import Testing


    extension Render3DGPUTests {
        @Suite("Terrain texture arrays", .enabled(if: GoldenFrame.isEnabled))
        @MainActor
        struct TerrainTextureArrays {
            @Test("Array allocation and sampled pixels honor 32 slices and a single-slice array view")
            func terrainTextureArrayCapacityAndPixels() async throws {
                unsafe RenderEngine.configurations.preferredBackend = .saga
                try RenderEngine.setupRenderEngine()
                let engine = try #require(unsafe RenderEngine.shared)
                try #require(engine.type == .saga)
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
                let probe = try WESLRenderProbe(source: """
                import package::fullscreen::{FullscreenVertex, fullscreenVertex};

                @vertex fn vertexMain(@builtin(vertex_index) index: u32) -> FullscreenVertex {
                    return fullscreenVertex(index);
                }

                @group(0) @binding(0) var layers: texture_2d_array<f32>;
                @group(0) @binding(1) var layerSampler: sampler;

                @fragment fn fragmentMain(input: FullscreenVertex) -> @location(0) vec4f {
                    let layer = select(0, \(count - 1), input.position.x >= 2.0);
                    return textureSample(layers, layerSampler, vec2f(0.5, 0.5), layer);
                }
                """)
                let pipeline = device.createRenderPipeline(
                    from: RenderPipelineDescriptor(
                        vertex: probe.vertex,
                        fragment: probe.fragment,
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
                pass.setFragmentTexture(array, slot: try probe.textureSlot(0))
                pass.setFragmentSamplerState(array.sampler, slot: try probe.samplerSlot(1))
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                pass.endRenderPass()
                await WESLRenderProbe.complete(command)
                return try #require(try await device.readImage(from: target))
            }
        }
    }
#endif
