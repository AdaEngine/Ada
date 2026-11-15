#if os(visionOS)
    @_spi(Internal) import AdaRender
    import CompositorServices
    import Metal

    /// Converts Ada's forward-depth offscreen result to the compositor's reverse-depth attachments.
    @available(visionOS 26.0, *)
    @MainActor
    final class ImmersivePresentation {
        private let device: any RenderDevice
        private let metalDevice: any MTLDevice
        private let pipeline: any MTLRenderPipelineState
        private let depthState: any MTLDepthStencilState
        private let preservesPassthrough: Bool

        init(device: any RenderDevice, metalDevice: any MTLDevice, colorFormat: MTLPixelFormat,
             depthFormat: MTLPixelFormat, preservesPassthrough: Bool) throws {
            #if SAGA_METAL_NATIVE_PASS
            guard MetalInterop.supportsSAGAMetalPass(on: device) else {
                throw ImmersiveRendererError.metalResourceUnavailable
            }
            self.device = device
            self.metalDevice = metalDevice
            self.preservesPassthrough = preservesPassthrough
            let library = try metalDevice.makeLibrary(source: ImmersiveCompositionShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "immersiveVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "immersiveFragment")
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            descriptor.depthAttachmentPixelFormat = depthFormat
            descriptor.inputPrimitiveTopology = .triangle
            pipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor)
            let depth = MTLDepthStencilDescriptor()
            depth.depthCompareFunction = .always
            depth.isDepthWriteEnabled = true
            guard let depthState = metalDevice.makeDepthStencilState(descriptor: depth) else {
                throw ImmersiveRendererError.metalResourceUnavailable
            }
            self.depthState = depthState
            #else
            throw ImmersiveRendererError.metalResourceUnavailable
            #endif
        }

        typealias OverlayRecorder = (any MTLCommandBuffer, [ObjectIdentifier: any MTLBuffer]) -> Void

        #if SAGA_METAL_NATIVE_PASS
        /// Holds compositor state on the main actor while render work is queued.
        @MainActor
        private final class Submission {
            let drawable: LayerRenderer.Drawable
            let buffers: [any Buffer]
            let overlays: OverlayRecorder
            let isValid: () -> Bool
            let onSubmitted: () -> Void

            init(drawable: LayerRenderer.Drawable, buffers: [any Buffer], overlays: @escaping OverlayRecorder,
                 isValid: @escaping () -> Bool, onSubmitted: @escaping () -> Void) {
                self.drawable = drawable
                self.buffers = buffers
                self.overlays = overlays
                self.isValid = isValid
                self.onSubmitted = onSubmitted
            }
        }
        #endif

        func present(
            _ drawable: LayerRenderer.Drawable,
            eyes: [(RenderTexture, RenderTexture)],
            buffers: [any Buffer],
            overlays: @escaping OverlayRecorder,
            isValid: @escaping () -> Bool,
            onSubmitted: @escaping () -> Void
        ) async throws {
            #if SAGA_METAL_NATIVE_PASS
            let submission = Submission(drawable: drawable, buffers: buffers, overlays: overlays,
                                        isValid: isValid, onSubmitted: onSubmitted)
            try await MetalInterop.submitSAGAMetalPass(
                on: device, label: "Immersive compositor",
                textures: eyes.flatMap { [MetalInterop.NativePassUse<Texture>($0.0), .init($0.1)] },
                buffers: buffers.map { .init($0) },
                onCommitted: { submission.onSubmitted() }
            ) { commands, textures, nativeBuffers in
                guard submission.isValid() else { throw CancellationError() }
                guard commands.device.registryID == self.metalDevice.registryID else {
                    throw ImmersiveRendererError.incompatibleMetalDevice
                }
                let nativeEyes = stride(from: 0, to: textures.count, by: 2).map { (textures[$0], textures[$0 + 1]) }
                try self.encode(submission.drawable, eyes: nativeEyes, commands: commands)
                var resolvedBuffers: [ObjectIdentifier: any MTLBuffer] = [:]
                for (buffer, native) in zip(submission.buffers, nativeBuffers) {
                    resolvedBuffers[ObjectIdentifier(buffer)] = native
                }
                submission.overlays(commands, resolvedBuffers)
                submission.drawable.encodePresent(commandBuffer: commands)
            }
            #else
            throw ImmersiveRendererError.metalResourceUnavailable
            #endif
        }

        private func encode(
            _ drawable: LayerRenderer.Drawable, eyes: [(any MTLTexture, any MTLTexture)],
            commands: any MTLCommandBuffer
        ) throws {
            for (index, view) in drawable.views.enumerated() {
                guard index < eyes.count else { throw ImmersiveRendererError.missingEyeTarget }
                let (color, depth) = eyes[index]
                let map = view.textureMap
                let textureIndex = map.textureIndex
                let pass = MTLRenderPassDescriptor()
                let rateMaps = drawable.rasterizationRateMaps
                let rateMap = rateMaps.indices.contains(textureIndex) ? rateMaps[textureIndex] : nil
                pass.rasterizationRateMap = rateMap
                let layeredFoveation = (rateMap?.layerCount ?? 1) > 1
                pass.renderTargetArrayLength = layeredFoveation ? (rateMap?.layerCount ?? 1) : 1
                pass.colorAttachments[0].texture = drawable.colorTextures[textureIndex]
                pass.colorAttachments[0].slice = layeredFoveation ? 0 : map.sliceIndex
                let preserveOtherEye = layeredFoveation && drawable.views.prefix(index).contains { $0.textureMap.textureIndex == textureIndex }
                pass.colorAttachments[0].loadAction = preserveOtherEye ? .load : .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: preservesPassthrough ? 0 : 1)
                pass.depthAttachment.texture = drawable.depthTextures[textureIndex]
                pass.depthAttachment.slice = layeredFoveation ? 0 : map.sliceIndex
                pass.depthAttachment.clearDepth = 0
                pass.depthAttachment.loadAction = preserveOtherEye ? .load : .clear
                pass.depthAttachment.storeAction = .store
                guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
                    throw ImmersiveRendererError.metalResourceUnavailable
                }
                encoder.setViewport(map.viewport)
                var layerIndex = UInt32(layeredFoveation ? map.sliceIndex : 0)
                unsafe encoder.setVertexBytes(&layerIndex, length: MemoryLayout<UInt32>.stride, index: 0)
                encoder.setRenderPipelineState(pipeline)
                encoder.setDepthStencilState(depthState)
                encoder.setFragmentTexture(color, index: 0)
                encoder.setFragmentTexture(depth, index: 1)
                var passthrough: UInt32 = preservesPassthrough ? 1 : 0
                unsafe encoder.setFragmentBytes(&passthrough, length: MemoryLayout<UInt32>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        }

        /// A nonblocking fence before rendering the next eye with shared per-view uniform scratch.
        func finishEye() async throws {
            #if SAGA_METAL_NATIVE_PASS
            try await MetalInterop.submitSAGAMetalPass(on: device, label: "Immersive eye fence") { _, _, _ in }
            #else
            throw ImmersiveRendererError.metalResourceUnavailable
            #endif
        }
    }
#endif
