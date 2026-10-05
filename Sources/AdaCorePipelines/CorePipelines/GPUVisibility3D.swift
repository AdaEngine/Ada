import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// Per-camera resources and current-frame indirect results. No occlusion state is shared across views.
public struct GPUVisibility3DState: Resource {
    private struct Entry {
        var processor: (any GPUVisibilityProcessor)?
        var color: RenderTexture?
        var depth: RenderTexture?
        var output: GPUVisibilityOutput?
    }
    private var entries: [Entity.ID: Entry] = [:]
    private var pipelines = RenderPipelines(configurator: DirectionalShadow3DPipeline())
    private var constants = FrameUniformCache3D<DirectionalShadowViewUniform>()
    public init() {}

    public mutating func retainViews(_ active: [Entity.ID]) {
        for key in entries.keys where !active.contains(key) { entries.removeValue(forKey: key) }
        constants.retainViews(active)
    }

    mutating func clearOutput(for view: Entity.ID) { entries[view]?.output = nil }

    public func output(for view: Entity.ID) -> GPUVisibilityOutput? { entries[view]?.output }

    mutating func encode(
        view: Entity.ID,
        size: SizeInt,
        projection: Transform3D,
        items: inout [Opaque3DRenderItem],
        candidates: [GPUVisibilityCandidate],
        buffers: inout Active3DInstanceBuffers,
        device: RenderDevice,
        queue: CommandQueue,
        materials: PBR3DUniforms,
        identityPalette: (any UniformBuffer)?,
        metrics: Render3DPerformanceMetrics?
    ) -> CommandBuffer? {
        var entry = entries.removeValue(forKey: view) ?? Entry(processor: device.createGPUVisibilityProcessor())
        entry.output = nil
        defer { entries[view] = entry }
        guard let processor = entry.processor, let instances = buffers.instances?.buffer,
            !items.isEmpty, !candidates.isEmpty, let defaults = buffers.defaults, let identityPalette
        else {
            return nil
        }
        if entry.color?.size != size {
            entry.color = RenderTexture(size: size, scaleFactor: 1, format: .rgba_32f, debugLabel: "Occlusion Depth")
            entry.depth = RenderTexture(size: size, scaleFactor: 1, format: .depth_32f_stencil8, debugLabel: "Occlusion Z")
        }
        guard let color = entry.color, let depth = entry.depth else {
            return nil
        }
        let command = queue.makeCommandBuffer()
        command.label = "GPU visibility prepass and compaction"
        let pass = command.beginRenderPass(
            .init(
                label: "Current-frame occluders",
                colorAttachments: [.init(texture: color, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .white)],
                depthStencilAttachment: .init(
                    texture: depth,
                    depthOperation: .init(loadAction: .clear, storeAction: .dontCare),
                    stencilOperation: .init(loadAction: .clear, storeAction: .dontCare)
                )
            )
        )
        let viewUniform = constants.write(
            DirectionalShadowViewUniform(viewProjection: projection, tileBounds: [0, 0, Float(size.width), Float(size.height)]),
            view: view,
            device: device
        )
        pass.setViewport(Rect(origin: .zero, size: Size(width: Float(size.width), height: Float(size.height))))
        pass.setVertexBuffer(viewUniform, offset: 0, slot: GlobalBufferIndex.viewUniform)
        for item in items {
            // Alpha masks/facing/distance dithering use the same shader rules as visible geometry.
            guard (item.material as? PBRMaterial)?.alphaMode != .blend, let range = item.batchRange,
                let material = materials.buffer(for: item.material)
            else { continue }
            let part = item.mesh.models[item.modelIndex].parts[item.partIndex]
            pass.setRenderPipelineState(pipelines.pipeline(for: part.vertexDescriptor, device: device))
            pass.setVertexBuffer(part.vertexBuffer, offset: 0, slot: 0)
            pass.setVertexBuffer(wrap(instances), offset: Int(range.lowerBound) * MemoryLayout<Flat3DInstanceData>.stride, slot: 3)
            pass.setVertexBuffer(defaults, offset: 0, slot: 4)
            let base = (item.material as? PBRMaterial)?.baseColorTexture ?? Texture2D.whiteTexture
            pass.setResourceSet(
                .init(bindings: [
                    .init(binding: 15, shaderStages: .fragment, resource: .uniformBuffer(material, offset: 0)),
                    .init(binding: 4, shaderStages: .fragment, resource: .texture(base)),
                    .init(binding: 7, shaderStages: .fragment, resource: .sampler(base.sampler)),
                    .init(binding: Skinning3DUniforms.binding, shaderStages: .vertex, resource: .uniformBuffer(item.skinningBuffer ?? identityPalette, offset: 0)),
                ]),
                index: 0
            )
            pass.setIndexBuffer(part.indexBuffer, offset: 0)
            pass.drawIndexed(indexCount: part.indexCount, indexBufferOffset: 0, instanceCount: Int(range.count))
        }
        pass.endRenderPass()
        let draws = items.map { IndexedIndirectArguments(indexCount: UInt32($0.mesh.models[$0.modelIndex].parts[$0.partIndex].indexCount), instanceCount: UInt32($0.batchRange?.count ?? 0)) }
        guard
            let output = processor.encode(
                on: command,
                depth: color,
                viewProjection: projection,
                instances: instances,
                instanceStride: MemoryLayout<Flat3DInstanceData>.stride,
                candidates: candidates,
                draws: draws
            )
        else {
            command.commit()
            return nil
        }
        entry.output = output
        buffers.instances = wrap(output.instances)
        buffers.indirectArguments = output.arguments
        for index in items.indices { items[index].indirectArgumentOffset = index * MemoryLayout<IndexedIndirectArguments>.stride }
        if let metrics { command.addCompletedTimingHandler { metrics.record(pass: "gpu-visibility", seconds: $0) } }
        return command
    }
    private func wrap(_ buffer: any Buffer) -> BufferData<Flat3DInstanceData> {
        var data = BufferData<Flat3DInstanceData>(elements: [])
        data.buffer = buffer
        return data
    }
}
