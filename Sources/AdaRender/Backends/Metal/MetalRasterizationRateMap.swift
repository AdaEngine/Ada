#if METAL
    import AdaUtils
    import Math
    import Metal
    import Synchronization

    /// The map and parameter buffer are immutable frame snapshots. Only the reusable cache
    /// mutates, under its mutex. All GPU uses must be submitted on the engine's ordered queue.
    final class MetalRasterizationRateMap: RasterizationRateMap, @unchecked Sendable {
        let map: any MTLRasterizationRateMap
        let layer: Int
        let parameters: any MTLBuffer
        private final class StorageCache: Sendable {
            let value = Mutex<Storage?>(nil)
        }
        private let cache: StorageCache

        var screenSize: SizeInt { SizeInt(width: map.screenSize.width, height: map.screenSize.height) }

        init(map: any MTLRasterizationRateMap, layer: Int, previous: MetalRasterizationRateMap? = nil) throws {
            guard layer >= 0, layer < map.layerCount else { throw FoveatedRenderingError.invalidRateMap }
            self.map = map
            self.layer = layer
            guard let parameters = map.device.makeBuffer(length: map.parameterDataSizeAndAlign.size, options: .storageModeShared) else {
                throw FoveatedRenderingError.metalResourceUnavailable
            }
            map.copyParameterData(buffer: parameters, offset: 0)
            self.parameters = parameters
            if let previous, previous.map.device.registryID == map.device.registryID {
                cache = previous.cache
            } else {
                cache = StorageCache()
            }
        }

        /// Immutable resource references; texture writes are ordered GPU commands, never CPU mutations.
        struct Storage: @unchecked Sendable {
            let size: MTLSize
            let layers: Int
            let colors: [any MTLTexture]
            let depth: (any MTLTexture)?
            let pipeline: any MTLRenderPipelineState
            let depthState: any MTLDepthStencilState
        }

        func beginPass(_ descriptor: RenderPassDescriptor, commands: any MTLCommandBuffer) throws -> FoveatedRenderPass {
            let colors = try descriptor.colorAttachments.map { attachment in
                guard let texture = MetalInterop.texture(attachment.texture), texture.textureType == .type2D,
                    texture.width == screenSize.width, texture.height == screenSize.height,
                    texture.sampleCount == 1, attachment.resolveTexture == nil, attachment.operation?.loadAction == .clear
                else { throw FoveatedRenderingError.invalidAttachments }
                return texture
            }
            let depth = descriptor.depthStencilAttachment.flatMap { MetalInterop.texture($0.texture) }
            guard !colors.isEmpty, colors.count <= 4, commands.device.registryID == map.device.registryID,
                descriptor.depthStencilAttachment == nil || depth != nil,
                depth == nil || (depth?.width == screenSize.width && depth?.height == screenSize.height && depth?.textureType == .type2D)
            else { throw FoveatedRenderingError.invalidAttachments }
            // Metal validates all map layers even when only one eye is drawn in this pass.
            let sizes = (0..<map.layerCount).map { map.physicalSize(layer: $0) }
            let size = MTLSize(width: sizes.map(\.width).max() ?? 1, height: sizes.map(\.height).max() ?? 1, depth: 1)
            let storage = try cache.value.withLock { cached in
                if let current = cached, current.size.width == size.width, current.size.height == size.height,
                    current.layers == map.layerCount, current.colors.map(\.pixelFormat) == colors.map(\.pixelFormat),
                    current.depth?.pixelFormat == depth?.pixelFormat {
                    return current
                }
                let created = try makeStorage(colors: colors, depth: depth, size: size, previous: cached)
                cached = created
                return created
            }
            let pass = MTLRenderPassDescriptor()
            pass.rasterizationRateMap = map
            pass.renderTargetArrayLength = map.layerCount
            for (index, attachment) in descriptor.colorAttachments.enumerated() {
                pass.colorAttachments[index].texture = storage.colors[index]
                pass.colorAttachments[index].loadAction = .clear
                pass.colorAttachments[index].storeAction = .store
                pass.colorAttachments[index].clearColor = (attachment.clearColor ?? .black).toMetalClearColor
            }
            pass.depthAttachment.texture = storage.depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 1
            if storage.depth?.pixelFormat == .depth32Float_stencil8 {
                pass.stencilAttachment.texture = storage.depth
                pass.stencilAttachment.loadAction = .clear
                pass.stencilAttachment.storeAction = .dontCare
            }
            guard let native = commands.makeRenderCommandEncoder(descriptor: pass) else {
                throw FoveatedRenderingError.metalResourceUnavailable
            }
            native.label = descriptor.label
            let encoder = MetalRenderCommandEncoder(renderEncoder: native, device: map.device, renderTargetLayer: UInt32(layer))
            return FoveatedRenderPass(encoder: encoder) { [self] in
                try resolve(storage, colors: colors, depth: depth, commands: commands)
            }
        }

        private func makeStorage(colors: [any MTLTexture], depth: (any MTLTexture)?, size: MTLSize, previous: Storage?) throws -> Storage {
            func makeTexture(_ format: MTLPixelFormat) throws -> any MTLTexture {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format, width: size.width, height: size.height, mipmapped: false
                )
                descriptor.textureType = .type2DArray
                descriptor.arrayLength = map.layerCount
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead]
                guard let texture = map.device.makeTexture(descriptor: descriptor) else {
                    throw FoveatedRenderingError.metalResourceUnavailable
                }
                texture.label = "Foveated geometry"
                return texture
            }
            let packedColors = try colors.map { try makeTexture($0.pixelFormat) }
            let packedDepth = try depth.map { try makeTexture($0.pixelFormat) }
            if let previous, previous.colors.map(\.pixelFormat) == colors.map(\.pixelFormat), previous.depth?.pixelFormat == depth?.pixelFormat {
                return Storage(
                    size: size,
                    layers: map.layerCount,
                    colors: packedColors,
                    depth: packedDepth,
                    pipeline: previous.pipeline,
                    depthState: previous.depthState
                )
            }
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            let library = try map.device.makeLibrary(source: Self.shader(colors: colors.count, depth: depth != nil), options: nil)
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "resolveVertex")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "resolveFragment")
            for (index, texture) in colors.enumerated() { pipelineDescriptor.colorAttachments[index].pixelFormat = texture.pixelFormat }
            pipelineDescriptor.depthAttachmentPixelFormat = depth?.pixelFormat ?? .invalid
            if depth?.pixelFormat == .depth32Float_stencil8 { pipelineDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8 }
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .always
            depthDescriptor.isDepthWriteEnabled = depth != nil
            guard let depthState = map.device.makeDepthStencilState(descriptor: depthDescriptor) else {
                throw FoveatedRenderingError.metalResourceUnavailable
            }
            return try Storage(
                size: size,
                layers: map.layerCount,
                colors: packedColors,
                depth: packedDepth,
                pipeline: map.device.makeRenderPipelineState(descriptor: pipelineDescriptor),
                depthState: depthState
            )
        }

        private func resolve(_ storage: Storage, colors: [any MTLTexture], depth: (any MTLTexture)?, commands: any MTLCommandBuffer) throws {
            let pass = MTLRenderPassDescriptor()
            for (index, texture) in colors.enumerated() {
                pass.colorAttachments[index].texture = texture
                pass.colorAttachments[index].loadAction = .dontCare
                pass.colorAttachments[index].storeAction = .store
            }
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .dontCare
            pass.depthAttachment.storeAction = .store
            if depth?.pixelFormat == .depth32Float_stencil8 {
                pass.stencilAttachment.texture = depth
                pass.stencilAttachment.loadAction = .clear
                pass.stencilAttachment.storeAction = .store
            }
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
                throw FoveatedRenderingError.metalResourceUnavailable
            }
            encoder.label = "Foveated geometry screen-space resolve"
            encoder.setRenderPipelineState(storage.pipeline)
            encoder.setDepthStencilState(storage.depthState)
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(screenSize.width), height: Double(screenSize.height), znear: 0, zfar: 1))
            encoder.setFragmentBuffer(parameters, offset: 0, index: 0)
            var layerIndex = UInt32(layer)
            unsafe encoder.setFragmentBytes(&layerIndex, length: MemoryLayout<UInt32>.stride, index: 1)
            for (index, texture) in storage.colors.enumerated() { encoder.setFragmentTexture(texture, index: index) }
            if let depth = storage.depth { encoder.setFragmentTexture(depth, index: colors.count) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        private static func shader(colors: Int, depth: Bool) -> String {
            let fields = (0..<colors).map { "float4 color\($0) [[color(\($0))]];" }.joined(separator: "\n")
            let textures = (0..<colors).map { "texture2d_array<float> color\($0) [[texture(\($0))]]" }.joined(separator: ",\n")
            let writes = (0..<colors).map { "out.color\($0) = color\($0).sample(nearest, uv, layer);" }.joined(separator: "\n")
            return """
                #include <metal_stdlib>
                using namespace metal;
                struct VertexOut { float4 position [[position]]; };
                struct FragmentOut { \(fields) \(depth ? "float depth [[depth(any)]];" : "") };
                vertex VertexOut resolveVertex(uint id [[vertex_id]]) {
                    float2 uv = float2((id << 1) & 2, id & 2);
                    return { float4(uv * 2 - 1, 0, 1) };
                }
                fragment FragmentOut resolveFragment(VertexOut in [[stage_in]],
                    constant rasterization_rate_map_data &data [[buffer(0)]], constant uint &layer [[buffer(1)]],
                    \(textures)\(depth ? ", depth2d_array<float> depth [[texture(\(colors))]]" : "")) {
                    rasterization_rate_map_decoder decoder(data);
                    float2 physical = decoder.map_screen_to_physical_coordinates(in.position.xy, layer);
                    float2 uv = physical / float2(color0.get_width(), color0.get_height());
                    // Use one geometry sample for every G-buffer and depth value to preserve edges.
                    constexpr sampler nearest(coord::normalized, address::clamp_to_edge, filter::nearest);
                    FragmentOut out;
                    \(writes)
                    \(depth ? "out.depth = depth.sample(nearest, uv, layer);" : "")
                    return out;
                }
                """
        }
    }
#endif
