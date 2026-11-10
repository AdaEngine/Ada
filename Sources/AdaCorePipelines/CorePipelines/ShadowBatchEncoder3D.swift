@_spi(Internal) import AdaRender
import AdaUtils

/// Encodes shadow-depth draws for prepared visibility lists.
///
/// A moving point light redraws six faces every frame, and each face draws most of the same batches.
/// The draw state of a batch (pipeline, material bindings, buffers) does not depend on the face, so it
/// is resolved once per encoder and reused by every face and cascade that draws the batch.
///
/// Within a face, draws are grouped by draw state. Shadow passes write the nearest depth with a
/// strict depth test, so the stored result does not depend on draw order. Each face binds its
/// instance buffer once and selects a batch's instances with `firstInstance`.
struct ShadowBatchEncoder3D {
    private struct Key: Hashable {
        var material: ObjectIdentifier
        var vertex: ObjectIdentifier
        var index: ObjectIdentifier
        var skin: ObjectIdentifier?
        var morph: ObjectIdentifier?
    }

    private struct State {
        var pipeline: any RenderPipeline
        /// Masked shader-graph materials bind a graph pipeline and the graph's own resources.
        var material: Material?
        var morphed: Bool
        var resources: RenderResourceSet?
        var morphResources: RenderResourceSet?
        var vertexBuffer: any VertexBuffer
        var indexBuffer: any IndexBuffer
        var indexCount: Int
    }

    private struct Draw {
        var state: Int32
        var firstInstance: Int32
        var instanceCount: Int32
    }

    private var keys: [Key: Int32] = [:]
    private var states: [State?] = []
    private var draws: [Draw] = []

    /// Items without a material parameter buffer or skinning palette are skipped instead of drawing
    /// with the previous draw's bindings.
    let requiresMaterialBuffer: Bool

    init(requiresMaterialBuffer: Bool) {
        self.requiresMaterialBuffer = requiresMaterialBuffer
    }

    /// Number of distinct draw states resolved so far (for tests and statistics).
    var resolvedStateCount: Int { states.count }

    /// Encodes every shadow-casting, non-blended item. The view uniform must already be bound.
    /// Returns the number of draws issued.
    @discardableResult
    mutating func encode<P: RenderPipelineConfigurator>(
        items: [Opaque3DRenderItem],
        instances: BufferData<Flat3DInstanceData>,
        defaults: BufferData<Flat3DDefaultVertexData>?,
        pass: RenderCommandEncoder,
        pipelines: inout RenderPipelines<P>,
        materials: PBR3DUniforms,
        identityPalette: (any UniformBuffer)?,
        device: RenderDevice
    ) -> Int where P.Configuration == Shadow3DConfiguration {
        draws.removeAll(keepingCapacity: true)
        for item in items {
            guard item.castShadows, let range = item.batchRange, !range.isEmpty else { continue }
            let state = resolve(item, pipelines: &pipelines, materials: materials, identityPalette: identityPalette, device: device)
            guard state >= 0 else { continue }
            draws.append(Draw(state: state, firstInstance: range.lowerBound, instanceCount: Int32(range.count)))
        }
        guard !draws.isEmpty else {
            return 0
        }
        // Stable grouping keeps the list order within a state.
        draws.sort { $0.state == $1.state ? $0.firstInstance < $1.firstInstance : $0.state < $1.state }
        pass.setVertexBuffer(instances, offset: 0, slot: 3)
        if let defaults { pass.setVertexBuffer(defaults, offset: 0, slot: 4) }
        var current: Int32 = -1
        var encoded = 0
        for draw in draws {
            guard let state = states[Int(draw.state)] else { continue }
            if draw.state != current || state.material != nil {
                if let material = state.material {
                    guard ShaderGraph3DPipeline.bindShadow(encoder: pass, base: state.pipeline, material: material, device: device, morph: state.morphed) else {
                        current = -1
                        continue
                    }
                } else {
                    pass.setRenderPipelineState(state.pipeline)
                }
                if let morphResources = state.morphResources { pass.setResourceSet(morphResources, index: 0) }
                if let resources = state.resources { pass.setResourceSet(resources, index: 0) }
                pass.setVertexBuffer(state.vertexBuffer, offset: 0, slot: 0)
                pass.setIndexBuffer(state.indexBuffer, offset: 0)
                current = draw.state
            }
            pass.drawIndexed(
                indexCount: state.indexCount,
                indexBufferOffset: 0,
                instanceCount: Int(draw.instanceCount),
                firstInstance: Int(draw.firstInstance)
            )
            encoded += 1
        }
        return encoded
    }

    /// Returns the state index for an item, or -1 when the item is not drawn into shadows.
    private mutating func resolve<P: RenderPipelineConfigurator>(
        _ item: Opaque3DRenderItem,
        pipelines: inout RenderPipelines<P>,
        materials: PBR3DUniforms,
        identityPalette: (any UniformBuffer)?,
        device: RenderDevice
    ) -> Int32 where P.Configuration == Shadow3DConfiguration {
        let part = item.mesh.models[item.modelIndex].parts[item.partIndex]
        let key = Key(
            material: ObjectIdentifier(item.material),
            vertex: ObjectIdentifier(part.vertexBuffer),
            index: ObjectIdentifier(part.indexBuffer),
            skin: item.skinningBuffer.map { ObjectIdentifier($0) },
            morph: item.morphBuffer.map { ObjectIdentifier($0) }
        )
        if let index = keys[key] {
            return states[Int(index)] == nil ? -1 : index
        }
        let index = Int32(states.count)
        keys[key] = index
        let pbr = item.material as? PBRMaterial
        let materialBuffer = materials.buffer(for: item.material)
        let palette = item.skinningBuffer ?? identityPalette
        guard pbr?.effectiveAlphaMode != .blend, !requiresMaterialBuffer || (materialBuffer != nil && palette != nil) else {
            states.append(nil)
            return -1
        }
        let morphed = item.morphBuffer != nil && part.morphTargets != nil
        let pipeline = pipelines.pipeline(for: Shadow3DConfiguration(vertex: part.vertexDescriptor, morph: morphed), device: device)
        var bindings: [RenderResourceSet.Binding] = []
        if let materialBuffer {
            let base = pbr?.baseColorTexture ?? Texture2D.whiteTexture
            bindings += [
                .init(binding: 15, shaderStages: .fragment, resource: .uniformBuffer(materialBuffer, offset: 0)),
                .init(binding: 4, shaderStages: .fragment, resource: .texture(base)),
                .init(binding: 7, shaderStages: .fragment, resource: .sampler(base.sampler)),
            ]
        }
        if let palette {
            bindings.append(.init(binding: Skinning3DUniforms.binding, shaderStages: .vertex, resource: .uniformBuffer(palette, offset: 0)))
        }
        var morphResources: RenderResourceSet?
        if morphed, let morphBuffer = item.morphBuffer, let morphSet = part.morphTargets {
            morphResources = RenderResourceSet(bindings: [
                .init(binding: Morph3DUniforms.binding, shaderStages: .vertex, resource: .uniformBuffer(morphBuffer, offset: 0)),
                .init(binding: Morph3DUniforms.textureBinding, shaderStages: .vertex, resource: .texture(morphSet.deltaTexture)),
            ])
        }
        let usesGraph = pbr.map { $0.effectiveAlphaMode == .mask && $0.graphMaterial != nil } ?? false
        states.append(
            State(
                pipeline: pipeline,
                material: usesGraph ? item.material : nil,
                morphed: morphed,
                resources: bindings.isEmpty ? nil : RenderResourceSet(bindings: bindings),
                morphResources: morphResources,
                vertexBuffer: part.vertexBuffer,
                indexBuffer: part.indexBuffer,
                indexCount: part.indexCount
            )
        )
        return index
    }
}
