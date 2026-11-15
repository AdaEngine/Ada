#if METAL
    import AdaUtils
    import Math
    import Metal
    import Synchronization
    #if SAGA_METAL_NATIVE_PASS
    import SAGAMetal
    import SAGATypes
    #endif

    /// The map and parameter buffer are immutable frame snapshots. Only the reusable cache
    /// mutates, under its mutex. All GPU uses must be submitted on the engine's ordered queue.
    final class MetalRasterizationRateMap: RasterizationRateMap, @unchecked Sendable {
        let map: any MTLRasterizationRateMap
        let layer: Int
        let parameters: any MTLBuffer
        private final class StorageCache: Sendable {
            #if SAGA_METAL_NATIVE_PASS
            let sagaTargets = Mutex<SAGAPackedTargets?>(nil)
            let sagaResolve = Mutex<SAGAResolveCache?>(nil)
            #endif
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

        struct ResolveState: Sendable {
            let pipeline: any MTLRenderPipelineState
            let depth: any MTLDepthStencilState
        }

        private func makeResolveState(colors: [MTLPixelFormat], depth: MTLPixelFormat?, sourceIsArray: Bool) throws -> ResolveState {
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            let library = try map.device.makeLibrary(source: Self.shader(colors: colors.count, depth: depth != nil, sourceIsArray: sourceIsArray), options: nil)
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "resolveVertex")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "resolveFragment")
            for (index, format) in colors.enumerated() { pipelineDescriptor.colorAttachments[index].pixelFormat = format }
            pipelineDescriptor.depthAttachmentPixelFormat = depth ?? .invalid
            if depth == .depth32Float_stencil8 { pipelineDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8 }
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .always
            depthDescriptor.isDepthWriteEnabled = depth != nil
            guard let depthState = map.device.makeDepthStencilState(descriptor: depthDescriptor) else {
                throw FoveatedRenderingError.metalResourceUnavailable
            }
            return try ResolveState(pipeline: map.device.makeRenderPipelineState(descriptor: pipelineDescriptor), depth: depthState)
        }

        private func resolve(from packed: [any MTLTexture], sourceDepth: (any MTLTexture)?,
                             to colors: [any MTLTexture], depth: (any MTLTexture)?,
                             state: ResolveState, commands: any MTLCommandBuffer) throws {
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
            encoder.setRenderPipelineState(state.pipeline)
            encoder.setDepthStencilState(state.depth)
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(screenSize.width), height: Double(screenSize.height), znear: 0, zfar: 1))
            encoder.setFragmentBuffer(parameters, offset: 0, index: 0)
            var layerIndex = UInt32(layer)
            unsafe encoder.setFragmentBytes(&layerIndex, length: MemoryLayout<UInt32>.stride, index: 1)
            for (index, texture) in packed.enumerated() { encoder.setFragmentTexture(texture, index: index) }
            if let sourceDepth { encoder.setFragmentTexture(sourceDepth, index: colors.count) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        private static func shader(colors: Int, depth: Bool, sourceIsArray: Bool) -> String {
            let suffix = sourceIsArray ? "_array" : ""
            let sampleArguments = sourceIsArray ? "nearest, uv, layer" : "nearest, uv"
            let fields = (0..<colors).map { "float4 color\($0) [[color(\($0))]];" }.joined(separator: "\n")
            let textures = (0..<colors).map { "texture2d\(suffix)<float> color\($0) [[texture(\($0))]]" }.joined(separator: ",\n")
            let writes = (0..<colors).map { "out.color\($0) = color\($0).sample(\(sampleArguments));" }.joined(separator: "\n")
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
                    \(textures)\(depth ? ", depth2d\(suffix)<float> depth [[texture(\(colors))]]" : "")) {
                    rasterization_rate_map_decoder decoder(data);
                    float2 physical = decoder.map_screen_to_physical_coordinates(in.position.xy, layer);
                    float2 uv = physical / float2(color0.get_width(), color0.get_height());
                    // Use one geometry sample for every G-buffer and depth value to preserve edges.
                    constexpr sampler nearest(coord::normalized, address::clamp_to_edge, filter::nearest);
                    FragmentOut out;
                    \(writes)
                    \(depth ? "out.depth = depth.sample(\(sampleArguments));" : "")
                    return out;
                }
                """
        }
    }

    #if SAGA_METAL_NATIVE_PASS
    extension MetalRasterizationRateMap {
        private struct SAGAPackedTargets: Sendable {
            let textures: [SAGAGPUTexture]
            let size: SizeInt
            let layerCount: Int
        }

        private struct SAGAResolveCache: Sendable {
            let colors: [MTLPixelFormat]
            let depth: MTLPixelFormat?
            let sourceIsArray: Bool
            let state: ResolveState
        }

        func beginSAGAPass(_ descriptor: RenderPassDescriptor, commands: SAGACommandBuffer) throws -> FoveatedRenderPass {
            let colorCount = descriptor.colorAttachments.count
            guard colorCount > 0, colorCount <= Int(commands.context.capabilities.maxColorAttachments),
                  descriptor.colorAttachments.allSatisfy({
                      $0.resolveTexture == nil && $0.operation?.loadAction == .clear && $0.operation?.storeAction == .store
                  }),
                  [descriptor.depthStencilAttachment?.depthOperation, descriptor.depthStencilAttachment?.stencilOperation].compactMap({ $0 })
                  .allSatisfy({ $0.loadAction == .clear && $0.storeAction == .store })
            else { throw FoveatedRenderingError.invalidAttachments }
            let hasDepth = descriptor.depthStencilAttachment != nil
            let outputs = descriptor.colorAttachments.map(\.texture)
                + [descriptor.depthStencilAttachment?.texture].compactMap { $0 }
            let destination = try outputs.map { output in
                guard let texture = output.gpuTexture as? SAGAGPUTexture, texture.context === commands.context,
                      texture.size == screenSize, output.textureType == .texture2D else {
                    throw FoveatedRenderingError.invalidAttachments
                }
                return texture
            }
            let sizes = (0..<map.layerCount).map { map.physicalSize(layer: $0) }
            let size = SizeInt(width: sizes.map(\.width).max() ?? 1, height: sizes.map(\.height).max() ?? 1)
            let sourceIsArray = map.layerCount > 1
            let formats = destination.map(\.pixelFormat)
            let source = try cache.sagaTargets.withLock { cached -> [SAGAGPUTexture] in
                if let cached, cached.size == size, cached.layerCount == map.layerCount,
                   cached.textures.first?.context === commands.context, cached.textures.map(\.pixelFormat) == formats {
                    return cached.textures
                }
                let textures = try formats.map { format in
                    var descriptor = TextureDescriptor(
                        width: size.width, height: size.height, pixelFormat: format,
                        textureUsage: [.renderTarget, .read], textureType: sourceIsArray ? .texture2DArray : .texture2D,
                        debugLabel: "SAGA foveated geometry"
                    )
                    descriptor.arrayLength = map.layerCount
                    return try SAGAGPUTexture(context: commands.context, descriptor: descriptor)
                }
                cached = SAGAPackedTargets(textures: textures, size: size, layerCount: map.layerCount)
                return textures
            }
            let packed = zip(source, outputs).map { Texture2D(gpuTexture: $0, sampler: $1.sampler, size: size) }
            var packedDescriptor = descriptor
            for index in 0..<colorCount {
                packedDescriptor.colorAttachments[index].texture = packed[index]
            }
            if hasDepth { packedDescriptor.depthStencilAttachment?.texture = packed[colorCount] }
            let encoder = SAGARenderCommandEncoder(buffer: commands, descriptor: packedDescriptor)
            encoder.rateMap = try MetalRasterizationRateBinding(map: map, layer: UInt32(layer))
            return FoveatedRenderPass(encoder: encoder) { [self] in
                commands.append {
                    let sourceIDs = try source.map { try $0.slot.get() }
                    let destinationIDs = try destination.map { try $0.slot.get() }
                    let uses = sourceIDs.map { NativePass.Use($0, .read) } + destinationIDs.map { NativePass.Use($0, .write) }
                    return .native(NativePass.onMainActor(label: "Foveated geometry resolve", uses: uses) { context in
                        guard let metal = context as? MetalNativePassContext else { throw FoveatedRenderingError.unsupportedBackend }
                        let sources = try sourceIDs.map { try metal.texture($0) }
                        let targets = try destinationIDs.map { try metal.texture($0) }
                        let colors = Array(targets.prefix(colorCount))
                        let targetDepth = hasDepth ? targets.last : nil
                        let colorFormats = colors.map(\.pixelFormat)
                        let depthFormat = targetDepth?.pixelFormat
                        let state = try self.cache.sagaResolve.withLock { cached in
                            if let cached, cached.colors == colorFormats, cached.depth == depthFormat, cached.sourceIsArray == sourceIsArray {
                                return cached.state
                            }
                            let state = try self.makeResolveState(colors: colorFormats, depth: depthFormat, sourceIsArray: sourceIsArray)
                            cached = SAGAResolveCache(colors: colorFormats, depth: depthFormat, sourceIsArray: sourceIsArray, state: state)
                            return state
                        }
                        try self.resolve(from: Array(sources.prefix(colorCount)), sourceDepth: hasDepth ? sources.last : nil,
                                         to: colors, depth: targetDepth, state: state, commands: metal.commandBuffer)
                    })
                }
            }
        }
    }
    #endif
#endif
