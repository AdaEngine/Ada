import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// GPU culling results of one frame's shadow views: per caster, per meshlet cluster, or both.
struct GPUShadowCullResult: Sendable {
    var casters: GPUShadowCullOutput?
    var clusters: GPUShadowClusterCullOutput?
}

/// Per-camera GPU shadow culling owned by one shadow render node.
struct GPUShadowCull3D: Sendable {
    private var processors: [Entity.ID: any GPUShadowCullProcessor] = [:]
    private var clusterProcessors: [Entity.ID: any GPUShadowClusterCullProcessor] = [:]
    private var unavailable: Set<Entity.ID> = []

    mutating func retainViews(_ active: [Entity.ID]) {
        for key in processors.keys where !active.contains(key) { processors.removeValue(forKey: key) }
        for key in clusterProcessors.keys where !active.contains(key) { clusterProcessors.removeValue(forKey: key) }
        unavailable = unavailable.filter { active.contains($0) }
    }

    /// Whether the GPU path will draw this camera's registry casters; otherwise every caster takes the CPU path.
    /// `viewCount` is the most views one cull may contain; outputs larger than a baseline storage binding
    /// (128 MiB) keep the CPU path.
    /// Cluster casters need their own processor; argument outputs above ``GPUShadowClusterCullLimits`` keep the CPU path.
    mutating func isAvailable(camera: Entity.ID, registry: ShadowCasterRegistry3D, viewCount: Int, device: RenderDevice) -> Bool {
        let limit = 128 << 20
        let views = max(viewCount, 1)
        guard registry.isEnabled, registry.hasCasters || registry.hasClusterCasters, !unavailable.contains(camera) else { return false }
        if registry.hasCasters {
            guard registry.isInputValid,
                views * registry.input.casters.count * registry.input.instanceStride <= limit,
                views * registry.partCount * MemoryLayout<IndexedIndirectArguments>.stride <= limit
            else { return false }
        }
        if registry.hasClusterCasters {
            guard registry.isClusterInputValid,
                views * registry.clusterInput.clusters.count * MemoryLayout<IndexedIndirectArguments>.stride <= GPUShadowClusterCullLimits.argumentBytes
            else { return false }
        }
        if registry.hasCasters, processors[camera] == nil {
            guard let processor = device.createGPUShadowCullProcessor() else {
                unavailable.insert(camera)
                return false
            }
            processors[camera] = processor
        }
        if registry.hasClusterCasters, clusterProcessors[camera] == nil {
            guard let processor = device.createGPUShadowClusterCullProcessor() else {
                unavailable.insert(camera)
                return false
            }
            clusterProcessors[camera] = processor
        }
        return true
    }

    /// Encodes culling for `views` (in output order) before the shadow render pass on `command`.
    mutating func cull(
        camera: Entity.ID,
        registry: inout ShadowCasterRegistry3D,
        views: [GPUShadowCullView],
        command: CommandBuffer,
        device: RenderDevice
    ) -> GPUShadowCullResult? {
        guard !views.isEmpty else { return nil }
        registry.flushCopies(on: command)
        // Every GPU-path caster must be drawn: if either cull cannot be encoded, the caller takes the CPU path.
        var result = GPUShadowCullResult()
        if registry.hasCasters {
            guard let processor = processors[camera],
                let output = processor.encode(on: command, input: registry.input, views: views, firstInstance: device.supportsMultiDrawIndirect)
            else { return nil }
            result.casters = output
        }
        if registry.hasClusterCasters {
            guard let processor = clusterProcessors[camera],
                let output = processor.encode(on: command, input: registry.clusterInput, views: views)
            else { return nil }
            result.clusters = output
        }
        return result
    }

    /// Draws the registry casters culled for output view `view`. The view uniform must already be bound.
    /// Returns the number of indirect draw calls issued.
    @discardableResult
    static func draw<P: RenderPipelineConfigurator>(
        registry: ShadowCasterRegistry3D,
        output: GPUShadowCullResult,
        view: Int,
        pass: RenderCommandEncoder,
        pipelines: inout RenderPipelines<P>,
        device: RenderDevice
    ) -> Int where P.Configuration == Shadow3DConfiguration {
        var calls = 0
        if let casters = output.casters {
            calls += drawCasters(registry: registry, output: casters, view: view, pass: pass, pipelines: &pipelines, device: device)
        }
        if let clusters = output.clusters {
            calls += drawClusters(registry: registry, output: clusters, view: view, pass: pass, pipelines: &pipelines, device: device)
        }
        return calls
    }

    /// Draws the surviving clusters of each cluster caster in output view `view`: one count-driven multi-draw per part.
    private static func drawClusters<P: RenderPipelineConfigurator>(
        registry: ShadowCasterRegistry3D,
        output: GPUShadowClusterCullOutput,
        view: Int,
        pass: RenderCommandEncoder,
        pipelines: inout RenderPipelines<P>,
        device: RenderDevice
    ) -> Int where P.Configuration == Shadow3DConfiguration {
        // The output describes the input it culled; a registry that changed since would misalign its parts.
        guard view < output.viewCount, output.input.revision == registry.clusterInput.revision,
            registry.clusterParts.count == output.input.segments.count
        else { return 0 }
        var instances = BufferData<Flat3DInstanceData>(elements: [])
        instances.buffer = output.instances
        var calls = 0
        // Parts share pipelines and materials: rebind only what changes between consecutive parts.
        var boundDescriptor: VertexDescriptor?
        var boundMaterial: ObjectIdentifier?
        for (index, part) in registry.clusterParts.enumerated() {
            if boundDescriptor != part.descriptor {
                pass.setRenderPipelineState(pipelines.pipeline(for: Shadow3DConfiguration(vertex: part.descriptor, morph: false), device: device))
                pass.setVertexBuffer(instances, offset: 0, slot: 3)
                if let defaults = registry.defaults { pass.setVertexBuffer(defaults, offset: 0, slot: 4) }
                boundDescriptor = part.descriptor
            }
            if boundMaterial != ObjectIdentifier(part.material) {
                pass.setResourceSet(part.resources, index: 0)
                boundMaterial = ObjectIdentifier(part.material)
            }
            pass.setVertexBuffer(part.vertex, offset: 0, slot: 0)
            pass.setIndexBuffer(part.index, offset: 0)
            if pass.multiDrawIndexedIndirect(
                arguments: output.arguments,
                offset: output.argumentOffset(view: view, part: index),
                maxDrawCount: output.input.clusterCount(part: index),
                drawCountBuffer: output.counts,
                drawCountOffset: output.countOffset(view: view, part: index)
            ) {
                calls += 1
            }
        }
        return calls
    }

    private static func drawCasters<P: RenderPipelineConfigurator>(
        registry: ShadowCasterRegistry3D,
        output: GPUShadowCullOutput,
        view: Int,
        pass: RenderCommandEncoder,
        pipelines: inout RenderPipelines<P>,
        device: RenderDevice
    ) -> Int where P.Configuration == Shadow3DConfiguration {
        guard view < output.viewCount, output.partCount == registry.partCount else { return 0 }
        var instances = BufferData<Flat3DInstanceData>(elements: [])
        instances.buffer = output.instances
        let multiDraw = device.supportsMultiDrawIndirect
        var calls = 0
        for group in registry.groups {
            guard let buffers = registry.buffers(for: group) else { continue }
            pass.setRenderPipelineState(pipelines.pipeline(for: Shadow3DConfiguration(vertex: group.descriptor, morph: false), device: device))
            pass.setResourceSet(group.resources, index: 0)
            pass.setVertexBuffer(buffers.vertex, offset: 0, slot: 0)
            pass.setIndexBuffer(buffers.index, offset: 0)
            if let defaults = registry.defaults { pass.setVertexBuffer(defaults, offset: 0, slot: 4) }
            if multiDraw {
                pass.setVertexBuffer(instances, offset: 0, slot: 3)
                if pass.multiDrawIndexedIndirect(
                    arguments: output.arguments,
                    offset: output.argumentOffset(view: view, part: group.firstPart),
                    drawCount: group.partCount
                ) {
                    calls += 1
                    continue
                }
            }
            // Without multi-draw each part's arguments have firstInstance 0: select its instances by offset.
            // With it (if a multi-draw was refused) the arguments already carry firstInstance.
            for part in group.firstPart..<(group.firstPart + group.partCount) {
                let first = multiDraw ? 0 : output.firstInstance(view: view, segment: registry.input.segments[part])
                pass.setVertexBuffer(instances, offset: first * output.instanceStride, slot: 3)
                if pass.drawIndexedIndirect(arguments: output.arguments, offset: output.argumentOffset(view: view, part: part)) {
                    calls += 1
                }
            }
        }
        return calls
    }
}
