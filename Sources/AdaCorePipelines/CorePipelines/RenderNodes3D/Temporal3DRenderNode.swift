import AdaECS
import AdaRender
import AdaUtils
import Math

/// Encodes camera, rigid and skeletal motion, then resolves the scene before 2D/UI compositing.
public struct Temporal3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.TemporalResolve"
    @Query<Entity, Camera, RenderViewTarget, GlobalViewUniform, ExtractedCameraSource> private var cameras
    @ResMut<Temporal3DViews> private var views
    @ResMut<Temporal3DPipelines> private var pipelines
    @Res<VisibleMesh3DLists> private var lists
    @ResMut<ActiveMotion3DPass> private var motionPass
    @Res<Render3DTemporalStatistics> private var statistics
    @Res<RenderDeviceHandler> private var device
    @Res<Render3DPerformanceMetrics?> private var metrics

    public init() {}

    public func update(from world: World) {
        cameras.update(from: world)
        _views.update(from: world)
        _pipelines.update(from: world)
        _lists.update(from: world)
        _motionPass.update(from: world)
        _statistics.update(from: world)
        _device.update(from: world)
        _metrics.update(from: world)
        var active: [Entity.ID] = []
        cameras.forEach { _, _, _, _, source in active.append(source.entityId) }
        pipelines.uniform.retainViews(active)
        statistics.retainViews(active)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }
        var submitted: CommandBuffer?
        try cameras.forEach { entity, camera, target, uniform, source in
            guard entity == view, target.temporalUpscalingActive,
                let scaler = views.entries[source.entityId]?.scaler,
                let input = target.temporalInputTexture, let output = target.temporalResolvedTexture, let presentation = target.mainTexture,
                let depth = target.depthTexture, let motion = target.temporalMotionTexture,
                let reactive = target.temporalReactiveTexture, let outputDepth = target.temporalOutputDepthTexture
            else { return }
            let jittered = temporalViewUniform(uniform, target: target)
            let constants = Temporal3DUniform(
                currentViewProjection: uniform.viewProjectionMatrix,
                previousViewProjection: target.temporalPreviousViewProjection,
                inverseJitteredProjection: jittered.projectionMatrix.inverse,
                currentToPreviousView: target.temporalPreviousView * uniform.viewMatrix.inverse,
                parameters: Vector4(target.temporalJitter.x / Float(input.size.width), target.temporalJitter.y / Float(input.size.height), target.temporalReset ? 1 : 0, 0)
            )
            let buffer = pipelines.uniform.write(constants, view: source.entityId, device: device.renderDevice)
            var skyConstants = constants
            skyConstants.currentViewProjection = uniform.projectionMatrix
            skyConstants.previousViewProjection = target.temporalPreviousViewProjection * uniform.viewMatrix.inverse
            let skyBuffer = pipelines.uniform.write(skyConstants, view: source.entityId, pass: 1, device: device.renderDevice)
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "Temporal 3D Motion + MetalFX"
            let attachments: [RenderPassColorAttachmentDescriptor] = [
                .init(texture: motion, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black),
                .init(texture: reactive, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black),
            ]
            let sky = command.beginRenderPass(.init(label: "Sky Motion", colorAttachments: attachments, depthStencilAttachment: nil))
            sky.setViewport(camera.viewport.rect)
            sky.setRenderPipelineState(pipelines.skyPipeline(device: device.renderDevice))
            sky.setFragmentBuffer(skyBuffer, offset: 0, slot: 23)
            sky.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            sky.endRenderPass()

            let mesh = command.beginRenderPass(
                .init(
                    label: "Mesh Motion",
                    colorAttachments: attachments.map {
                        var value = $0
                        value.operation = .init(loadAction: .load, storeAction: .store)
                        return value
                    },
                    depthStencilAttachment: .init(texture: depth, depthOperation: .init(loadAction: .load, storeAction: .store))
                )
            )
            mesh.setViewport(camera.viewport.rect)
            mesh.setVertexBuffer(jittered, slot: GlobalBufferIndex.viewUniform)
            mesh.setVertexBuffer(buffer, offset: 0, slot: 23)
            motionPass.isEnabled = true
            do {
                defer { motionPass.isEnabled = false }
                try RenderItems<Opaque3DRenderItem>(items: lists.items(view: source.entityId, pass: -1)).render(with: mesh, world: context.world, view: view)
            }
            mesh.endRenderPass()

            let encoded = scaler.encode(
                commandBuffer: command,
                color: input,
                depth: depth,
                motion: motion,
                reactive: reactive,
                output: output,
                jitter: target.temporalJitter,
                reset: target.temporalReset
            )
            views.entries[source.entityId]?.encoded = encoded
            statistics.record(view: source.entityId, input: input.size, output: output.size, encoded: encoded, reset: target.temporalReset)
            let reconstructed = encoded || command.encodeSpatialUpscale(source: input, destination: output)
            var toneConstants = constants
            toneConstants.parameters.w = reconstructed ? 0 : 1
            let toneBuffer = pipelines.uniform.write(toneConstants, view: source.entityId, pass: 2, device: device.renderDevice)
            let tone = command.beginRenderPass(
                .init(
                    label: "Temporal Tone Map",
                    colorAttachments: [.init(texture: presentation, operation: .init(loadAction: .clear, storeAction: .store))],
                    depthStencilAttachment: nil
                )
            )
            tone.setViewport(Rect(x: 0, y: 0, width: Float(presentation.size.width), height: Float(presentation.size.height)))
            tone.setRenderPipelineState(pipelines.toneMapPipeline(device: device.renderDevice))
            tone.setFragmentBuffer(toneBuffer, offset: 0, slot: 23)
            tone.setResourceSet(
                .init(bindings: [
                    .init(binding: 0, shaderStages: .fragment, resource: .texture(reconstructed ? output : input)),
                    .init(binding: 1, shaderStages: .fragment, resource: .sampler(input.sampler)),
                ]),
                index: 0
            )
            tone.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            tone.endRenderPass()
            let depthPass = command.beginRenderPass(
                .init(
                    label: "Temporal Output Depth",
                    colorAttachments: [],
                    depthStencilAttachment: .init(
                        texture: outputDepth,
                        depthOperation: .init(loadAction: .clear, storeAction: .store),
                        stencilOperation: .init(loadAction: .clear, storeAction: .store)
                    )
                )
            )
            depthPass.setViewport(Rect(x: 0, y: 0, width: Float(output.size.width), height: Float(output.size.height)))
            depthPass.setRenderPipelineState(pipelines.depthPipeline(device: device.renderDevice))
            depthPass.setFragmentBuffer(buffer, offset: 0, slot: 23)
            depthPass.setResourceSet(
                .init(bindings: [
                    .init(binding: 0, shaderStages: .fragment, resource: .texture(depth)),
                    .init(binding: 1, shaderStages: .fragment, resource: .sampler(pipelines.sampler)),
                ]),
                index: 0
            )
            depthPass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            depthPass.endRenderPass()
            // Downstream 2D/UI passes use output pixels for projection, scaling and clipping.
            // The source-world camera stays unmodified and is extracted again next frame.
            var presentationCamera = camera
            presentationCamera.viewport.rect = Rect(x: 0, y: 0, width: Float(presentation.size.width), height: Float(presentation.size.height))
            entity.components[Camera.self] = presentationCamera
            if let metrics { command.addCompletedTimingHandler { metrics.record(pass: "temporal", seconds: $0) } }
            submitted = command
        }
        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}
