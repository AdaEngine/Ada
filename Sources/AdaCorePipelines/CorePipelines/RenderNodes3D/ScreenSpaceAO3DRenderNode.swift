import AdaECS
import AdaRender
import AdaUtils
import Math

/// Half-resolution SSAO followed by a depth/normal-aware bilateral filter.
public struct ScreenSpaceAO3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.SSAO"
    @Query<Entity, Camera, RenderViewTarget, GlobalViewUniform, ExtractedCameraSource> private var views
    @Res<ExtractedEnvironment3D> private var environments
    @ResMut<ScreenQuality3DPipelines> private var pipelines
    @ResMut<ScreenQuality3DScratch> private var scratch
    @Res<RenderDeviceHandler> private var device

    @Res<Render3DPerformanceMetrics?> private var metrics

    public init() {}
    public func update(from world: World) {
        _metrics.update(from: world)
        views.update(from: world)
        _environments.update(from: world)
        _pipelines.update(from: world)
        _scratch.update(from: world)
        _device.update(from: world)
        var activeViews: [Entity.ID] = []
        views.forEach { _, _, _, _, source in activeViews.append(source.entityId) }
        scratch.ao.retainViews(activeViews)
        scratch.retainCortaoViews(activeViews)
    }

    private func drawFullscreen(
        _ command: CommandBuffer,
        label: String,
        output: RenderTexture,
        pipeline: RenderPipeline,
        constants: BufferData<SSAO3DUniform>,
        textures: [(binding: Int, texture: Texture2D)],
        bindsSampler: Bool = true
    ) {
        let pass = command.beginRenderPass(RenderPassDescriptor(
            label: label,
            colorAttachments: [.init(texture: output, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .white)],
            depthStencilAttachment: nil
        ))
        pass.setViewport(Rect(x: 0, y: 0, width: Float(output.size.width), height: Float(output.size.height)))
        pass.setRenderPipelineState(pipeline)
        pass.setFragmentBuffer(constants, offset: 0, slot: 4)
        var bindings = textures.map { RenderResourceSet.Binding(binding: $0.binding, shaderStages: .fragment, resource: .texture($0.texture)) }
        if bindsSampler {
            bindings.append(.init(binding: 3, shaderStages: .fragment, resource: .sampler(pipelines.nearest)))
        }
        pass.setResourceSet(RenderResourceSet(bindings: bindings), index: 0)
        pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
        pass.endRenderPass()
    }

    private func encodeSSAO(
        _ command: CommandBuffer,
        view: Entity.ID,
        projection: Transform3D,
        parameters: Vector4,
        position: RenderTexture,
        normal: RenderTexture,
        raw: RenderTexture
    ) {
        let constants = scratch.ao.write(
            SSAO3DUniform(projection: projection, parameters: parameters, pass: Vector4(0, 0, 0, 0)),
            view: view,
            pass: 0,
            device: device.renderDevice
        )
        drawFullscreen(
            command,
            label: "SSAO 3D",
            output: raw,
            pipeline: pipelines.aoPipeline(device: device.renderDevice),
            constants: constants,
            textures: [(0, position), (1, normal), (2, Texture2D.whiteTexture)]
        )
    }

    private func encodeBilateral(
        _ command: CommandBuffer,
        view: Entity.ID,
        projection: Transform3D,
        parameters: Vector4,
        position: RenderTexture,
        normal: RenderTexture,
        raw: RenderTexture,
        filtered: RenderTexture,
        bentNormals: Bool
    ) {
        let constants = scratch.ao.write(
            SSAO3DUniform(projection: projection, parameters: parameters, pass: Vector4(1, bentNormals ? 1 : 0, 0, 0)),
            view: view,
            pass: 1,
            device: device.renderDevice
        )
        drawFullscreen(
            command,
            label: "SSAO Bilateral",
            output: filtered,
            pipeline: pipelines.aoPipeline(device: device.renderDevice),
            constants: constants,
            textures: [(0, position), (1, normal), (2, raw)]
        )
    }

    /// CORTAO: a compute dispatch builds the depth/normal pyramid, then a fragment pass traces rays against circular
    /// occluders into `raw`. Returns false when the device or target size cannot run it, so the caller falls back to SSAO.
    private func encodeCORTAO(
        _ command: CommandBuffer,
        view: Entity.ID,
        viewUniform: GlobalViewUniform,
        parameters: Vector4,
        temporal: Bool,
        bentNormals: Bool,
        position: RenderTexture,
        normal: RenderTexture,
        raw: RenderTexture
    ) -> RenderTexture? {
        let renderDevice = device.renderDevice
        let levelCount = ScreenQuality3DScratch.cortaoLevelCount
        guard position.size.width >= 1 << (levelCount - 1), position.size.height >= 1 << (levelCount - 1),
              let compute = pipelines.cortaoPyramidPipeline(device: renderDevice), compute.isReady,
              let encoder = command.beginComputePass(ComputePassDescriptor(label: "CORTAO Pyramid")) else {
            return nil
        }
        let projection = viewUniform.projectionMatrix
        let pyramid = scratch.cortaoPyramid(view: view, size: position.size, scale: position.scaleFactor)
        var bindings: [ComputeResourceSet.Binding] = [
            .init(binding: 0, resource: .sampledTexture(position, mipLevel: nil)),
            .init(binding: 1, resource: .sampledTexture(normal, mipLevel: nil)),
        ]
        for level in 0..<levelCount {
            bindings.append(.init(binding: 2 + level, resource: .storageTexture(pyramid, mipLevel: level)))
        }
        encoder.setComputePipelineState(compute)
        encoder.setResourceSet(ComputeResourceSet(bindings: bindings), index: 0)
        encoder.dispatch(threadgroups: SIMD3((position.size.width + 15) / 16, (position.size.height + 15) / 16, 1))
        encoder.endComputePass()

        // With accumulation the seed changes every frame so history averages the noise; without it the seed stays fixed.
        let accumulation = temporal
            ? scratch.advanceCortaoHistory(
                view: view,
                size: raw.size,
                scale: raw.scaleFactor,
                viewProjection: viewUniform.viewProjectionMatrix,
                viewMatrix: viewUniform.viewMatrix,
                bentNormals: bentNormals
            )
            : nil

        // Shader parameters: radius, intensity, sample count, maximum sampling radius as a fraction of the screen height;
        // the pass vector carries the normal-offset bias, the frame seed and whether to write a bent normal.
        let constants = scratch.cortao.write(
            SSAO3DUniform(
                projection: projection,
                parameters: Vector4(parameters.x, parameters.y, parameters.w, 0.2),
                pass: Vector4(parameters.z, Float(accumulation?.frame ?? 0), bentNormals ? 1 : 0, 0)
            ),
            view: view,
            pass: 0,
            device: renderDevice
        )
        drawFullscreen(
            command,
            label: "CORTAO 3D",
            output: raw,
            pipeline: pipelines.cortaoPipeline(device: renderDevice),
            constants: constants,
            textures: [(0, pyramid), (1, pipelines.cortaoOccluderTable())],
            bindsSampler: false
        )
        guard let accumulation else {
            return raw
        }

        // Reproject the previous frame's result into this frame and blend. The first frame, and any frame after a
        // resize, uses the new result alone.
        let reprojection = accumulation.previousViewProjection * viewUniform.viewMatrix.inverse
        let temporalConstants = scratch.cortaoTemporal.write(
            CortaoTemporalUniform(
                reprojection: reprojection,
                viewRotation: viewUniform.viewMatrix * accumulation.previousViewMatrix.inverse,
                parameters: Vector4(Self.temporalBlend, accumulation.isValid ? 1 : 0, Self.temporalDepthTolerance, bentNormals ? 1 : 0)
            ),
            view: view,
            pass: 0,
            device: renderDevice
        )
        let pass = command.beginRenderPass(RenderPassDescriptor(
            label: "CORTAO Temporal",
            colorAttachments: [
                .init(texture: accumulation.write, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .white),
                .init(texture: accumulation.writeAge, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black),
            ],
            depthStencilAttachment: nil
        ))
        pass.setViewport(Rect(x: 0, y: 0, width: Float(accumulation.write.size.width), height: Float(accumulation.write.size.height)))
        pass.setRenderPipelineState(pipelines.cortaoTemporalPipeline(device: renderDevice))
        pass.setFragmentBuffer(temporalConstants, offset: 0, slot: 4)
        pass.setResourceSet(RenderResourceSet(bindings: [
            .init(binding: 0, shaderStages: .fragment, resource: .texture(position)),
            .init(binding: 1, shaderStages: .fragment, resource: .texture(raw)),
            .init(binding: 2, shaderStages: .fragment, resource: .texture(accumulation.read)),
            .init(binding: 3, shaderStages: .fragment, resource: .sampler(pipelines.nearest)),
            .init(binding: 5, shaderStages: .fragment, resource: .texture(accumulation.readAge)),
        ]), index: 0)
        pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
        pass.endRenderPass()
        return accumulation.write
    }

    /// Lowest weight of the current frame in the accumulated result (about ten frames of history). New pixels start at
    /// full weight and approach this one as their history grows.
    private static let temporalBlend: Float = 0.1
    /// History is rejected when its depth differs from the reprojected depth by more than this fraction.
    private static let temporalDepthTolerance: Float = 0.02

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }
        var submitted: CommandBuffer?
        views.forEach { entity, camera, target, uniform, source in
            let settings = environments.environments[source.entityId]?.ambientOcclusion ?? ScreenSpaceAO3D()
            guard entity == view else {
                return
            }
            guard settings.isEnabled,
                let position = target.viewPositionMetallic3DTexture, let normal = target.normalRoughness3DTexture,
                let raw = target.ambientOcclusion3DRawTexture, let filtered = target.ambientOcclusion3DTexture
            else {
                // Nothing is produced this frame: later passes must not read stale bent normals or keep CORTAO targets.
                scratch.setBentNormals(view: source.entityId, false)
                scratch.releaseCortao(view: source.entityId)
                return
            }
            let parameters = Vector4(
                finiteRenderValue(settings.radius, fallback: 0.65, range: 0.05...3),
                finiteRenderValue(settings.intensity, fallback: 1.1, range: 0...3),
                finiteRenderValue(settings.bias, fallback: 0.025, range: 0.001...0.2),
                Float(min(max(settings.sampleCount, 8), 32))
            )
            let useCortao = if case .perspective = camera.projection {
                settings.technique == .cortao
            } else {
                false
            }
            if !useCortao {
                scratch.releaseCortao(view: source.entityId)
            } else if !settings.temporalAccumulation {
                scratch.releaseCortao(view: source.entityId, keepPyramid: true)
            }
            let command = renderContext.commandQueue.makeCommandBuffer()
            let viewUniform = temporalViewUniform(uniform, target: target)
            let projection = viewUniform.projectionMatrix
            var filterInput = raw
            var producedBentNormals = false
            command.label = "SSAO 3D + Bilateral"
            // CORTAO needs perspective projection and compute passes.
            if useCortao,
                let output = encodeCORTAO(
                    command,
                    view: source.entityId,
                    viewUniform: viewUniform,
                    parameters: parameters,
                    temporal: settings.temporalAccumulation,
                    bentNormals: settings.bentNormals,
                    position: position,
                    normal: normal,
                    raw: raw
                ) {
                filterInput = output
                producedBentNormals = settings.bentNormals
                command.label = "CORTAO 3D + Bilateral"
            } else {
                encodeSSAO(command, view: source.entityId, projection: projection, parameters: parameters, position: position, normal: normal, raw: raw)
            }
            encodeBilateral(
                command,
                view: source.entityId,
                projection: projection,
                parameters: parameters,
                position: position,
                normal: normal,
                raw: filterInput,
                filtered: filtered,
                bentNormals: producedBentNormals
            )
            scratch.setBentNormals(view: source.entityId, producedBentNormals)
            if let metrics {
                command.addCompletedTimingHandler { metrics.record(pass: "ssao", seconds: $0) }
            }
            submitted = command
        }
        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}
