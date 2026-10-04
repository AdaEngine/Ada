#if os(visionOS)
    @_spi(Internal) import AdaRender
    import CompositorServices
    import Metal

    /// Converts Ada's forward-depth offscreen result to the compositor's reverse-depth attachments.
    @available(visionOS 26.0, *)
    @MainActor
    final class ImmersivePresentation {
        let queue: any MTLCommandQueue
        private let pipeline: any MTLRenderPipelineState
        private let depthState: any MTLDepthStencilState

        init(queue: any MTLCommandQueue, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) throws {
            self.queue = queue
            let library = try queue.device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "immersiveVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "immersiveFragment")
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            descriptor.depthAttachmentPixelFormat = depthFormat
            pipeline = try queue.device.makeRenderPipelineState(descriptor: descriptor)
            let depth = MTLDepthStencilDescriptor()
            depth.depthCompareFunction = .always
            depth.isDepthWriteEnabled = true
            guard let depthState = queue.device.makeDepthStencilState(descriptor: depth) else {
                throw ImmersiveRendererError.metalResourceUnavailable
            }
            self.depthState = depthState
        }

        func present(_ drawable: LayerRenderer.Drawable, eyes: [(RenderTexture, RenderTexture)], onSubmitted: () -> Void) async throws {
            guard let commands = queue.makeCommandBuffer() else { throw ImmersiveRendererError.metalResourceUnavailable }
            for (index, view) in drawable.views.enumerated() {
                guard index < eyes.count,
                    let color = MetalInterop.texture(eyes[index].0),
                    let depth = MetalInterop.texture(eyes[index].1)
                else {
                    throw ImmersiveRendererError.missingEyeTarget
                }
                let map = view.textureMap
                let textureIndex = map.textureIndex
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = drawable.colorTextures[textureIndex]
                pass.colorAttachments[0].slice = map.sliceIndex
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.depthAttachment.texture = drawable.depthTextures[textureIndex]
                pass.depthAttachment.slice = map.sliceIndex
                pass.depthAttachment.clearDepth = 0
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .store
                guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
                    throw ImmersiveRendererError.metalResourceUnavailable
                }
                encoder.setViewport(map.viewport)
                encoder.setRenderPipelineState(pipeline)
                encoder.setDepthStencilState(depthState)
                encoder.setFragmentTexture(color, index: 0)
                encoder.setFragmentTexture(depth, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            drawable.encodePresent(commandBuffer: commands)
            try await complete(commands, retaining: eyes, onSubmitted: onSubmitted)
        }

        /// A nonblocking fence before rendering the next eye with shared per-view uniform scratch.
        func finishEye() async throws {
            guard let commands = queue.makeCommandBuffer() else { throw ImmersiveRendererError.metalResourceUnavailable }
            try await complete(commands, retaining: [])
        }

        private func complete(_ commands: any MTLCommandBuffer, retaining eyes: [(RenderTexture, RenderTexture)], onSubmitted: () -> Void = {}) async throws {
            let succeeded = await withCheckedContinuation { continuation in
                commands.addCompletedHandler { buffer in
                    // Explicitly retain sampled textures until the GPU is finished.
                    _ = eyes
                    continuation.resume(returning: buffer.status == .completed)
                }
                commands.commit()
                onSubmitted()
            }
            guard succeeded else { throw ImmersiveRendererError.gpuSubmissionFailed }
        }

        private static let shader = """
            #include <metal_stdlib>
            using namespace metal;
            struct VertexOut { float4 position [[position]]; float2 uv; };
            vertex VertexOut immersiveVertex(uint id [[vertex_id]]) {
                float2 uv = float2((id << 1) & 2, id & 2);
                return { float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv };
            }
            struct FragmentOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };
            fragment FragmentOut immersiveFragment(VertexOut in [[stage_in]],
                texture2d<float> color [[texture(0)]], depth2d<float> depth [[texture(1)]]) {
                constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
                constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
                // The existing 3D composite writes display-encoded sRGB into BGRA8.
            // Decode before writing to the compositor's sRGB attachment, which encodes once.
            float4 displayColor = color.sample(linearSampler, in.uv);
            float3 linearColor = select(displayColor.rgb / 12.92,
                pow((displayColor.rgb + 0.055) / 1.055, float3(2.4)), displayColor.rgb > 0.04045);
            return { float4(linearColor, displayColor.a), 1.0 - depth.sample(nearestSampler, in.uv) };
            }
            """
    }
#endif
