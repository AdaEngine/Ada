import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// Motion blur and lens response after scene reconstruction/DOF and before debug overlays, 2D and UI.
public struct CameraEffects3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.CameraEffects"
    @Query<Entity, Camera, RenderViewTarget, GlobalViewUniform, ExtractedCameraSource> private var cameras
    @Res<ExtractedEnvironment3D> private var environments
    @ResMut<CameraEffects3DViews> private var effects
    @ResMut<Temporal3DPipelines> private var motionPipelines
    @ResMut<ActiveMotion3DPass> private var motionPass
    @ResMut<Active3DInstanceBuffers> private var activeInstances
    @ResMut<View3DGPUScratch> private var viewUniforms
    @Res<RenderDeviceHandler> private var device
    @Res<Render3DPerformanceMetrics?> private var metrics
    @Res<ExtractedDebugLines3D> private var overlays
    private let notifiesCompletion: Bool

    public init(notifiesCompletion: Bool = true) { self.notifiesCompletion = notifiesCompletion }

    public func update(from world: World) {
        cameras.update(from: world)
        _environments.update(from: world)
        _effects.update(from: world)
        _motionPipelines.update(from: world)
        _motionPass.update(from: world)
        _activeInstances.update(from: world)
        _viewUniforms.update(from: world)
        _device.update(from: world)
        _metrics.update(from: world)
        _overlays.update(from: world)
        var active: [Entity.ID] = []
        cameras.forEach { _, _, _, _, source in active.append(source.entityId) }
        effects.retainViews(active)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        // Main3D prepares these lists during graph execution. A @Res snapshot captured by
        // update(from:) still contains last frame's instance ring and loses object velocity.
        guard let view = context.viewEntity, let lists = context.world.getResource(VisibleMesh3DLists.self) else { return [] }
        var submitted: CommandBuffer?
        try cameras.forEach { entity, camera, target, uniform, source in
            guard entity == view else { return }
            guard let environment = environments.environments[source.entityId], !environment.debugView.replacesFinalImage,
                  environment.postProcess.lens.changesImage || environment.postProcess.motionBlur.changesImage,
                  let output = target.mainTexture, let position = target.viewPositionMetallic3DTexture
            else { effects.discard(view: source.entityId); return }

            let lens = environment.postProcess.lens.sanitized
            let blur = environment.postProcess.motionBlur.sanitized
            let scratch = effects.scratch(view: source.entityId, like: output)
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "Camera Optics + Motion Blur 3D"
            let effectPipeline = effects.pipeline(device: device.renderDevice)
            var motionTexture: Texture = Texture2D.whiteTexture
            if blur.changesImage {
                if target.temporalUpscalingActive, let existing = target.temporalMotionTexture {
                    motionTexture = existing
                } else if let depth = target.depthTexture {
                    let textures = effects.motionTextures(view: source.entityId, like: output)
                    motionTexture = textures.motion
                    let history = effects.history(view: source.entityId, uniform: uniform, size: output.size)
                    let constants = Temporal3DUniform(
                        currentViewProjection: uniform.viewProjectionMatrix,
                        previousViewProjection: history.previousViewProjection,
                        inverseJitteredProjection: uniform.projectionMatrix.inverse,
                        currentToPreviousView: history.previousView * uniform.viewMatrix.inverse,
                        parameters: Vector4(0, 0, history.reset ? 1 : 0, 0)
                    )
                    let buffer = motionPipelines.uniform.write(constants, view: source.entityId, pass: 10, device: device.renderDevice)
                    var skyConstants = constants
                    skyConstants.currentViewProjection = uniform.projectionMatrix
                    skyConstants.previousViewProjection = history.previousViewProjection * uniform.viewMatrix.inverse
                    let skyBuffer = motionPipelines.uniform.write(skyConstants, view: source.entityId, pass: 11, device: device.renderDevice)
                    let attachments: [RenderPassColorAttachmentDescriptor] = [
                        .init(texture: textures.motion, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black),
                        .init(texture: textures.reactive, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black),
                    ]
                    let sky = command.beginRenderPass(.init(label: "Camera Blur Sky Motion", colorAttachments: attachments, depthStencilAttachment: nil))
                    sky.setViewport(camera.viewport.rect)
                    sky.setRenderPipelineState(motionPipelines.skyPipeline(device: device.renderDevice))
                    sky.setFragmentBuffer(skyBuffer, offset: 0, slot: 23)
                    sky.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                    sky.endRenderPass()

                    let pass = command.beginRenderPass(.init(label: "Camera Blur Object Motion", colorAttachments: attachments.map {
                        var attachment = $0
                        attachment.operation = .init(loadAction: .load, storeAction: .store)
                        return attachment
                    }, depthStencilAttachment: .init(texture: depth, depthOperation: .init(loadAction: .load, storeAction: .store),
                        stencilOperation: .init(loadAction: .load, storeAction: .store))))
                    pass.setViewport(camera.viewport.rect)
                    let viewBuffer = viewUniforms.cache.write(uniform, view: source.entityId, pass: 1, device: device.renderDevice)
                    pass.setVertexBuffer(viewBuffer, offset: 0, slot: GlobalBufferIndex.viewUniform)
                    pass.setVertexBuffer(buffer, offset: 0, slot: 23)
                    _activeInstances.wrappedValue = lists.buffers(view: source.entityId, pass: -1)
                    motionPass.isEnabled = true
                    do {
                        defer { motionPass.isEnabled = false }
                        try RenderItems<Opaque3DRenderItem>(items: lists.items(view: source.entityId, pass: -1)).render(with: pass, world: context.world, view: view)
                    }
                    pass.endRenderPass()
                }
            } else {
                effects.discardMotion(view: source.entityId)
            }
            var passIndex = 0
            func encode(copy: Bool, texture: Texture, destination: RenderTexture, viewport: Rect) {
                let constants = effects.uniform.write(CameraEffects3DUniform(
                    lens: lens.isEnabled ? Vector4(lens.distortion, lens.chromaticAberration, lens.edgeSoftness, lens.filmGrain) : .zero,
                    blur: Vector4(blur.changesImage ? blur.shutterAngle / 360 : 0, blur.maximumVelocity, Float(blur.sampleCount), copy ? 1 : 0),
                    size: Vector4(1 / Float(output.size.width), 1 / Float(output.size.height), Float(effects.frame % 4096), 0),
                    rain: Vector4(lens.rainAmount, lens.rainTime, Float(output.size.width) / Float(output.size.height), 0)
                ), view: source.entityId, pass: passIndex, device: device.renderDevice)
                passIndex += 1
                let pass = command.beginRenderPass(.init(label: copy ? "Camera Effects Copy" : "Camera Effects Resolve",
                    colorAttachments: [.init(texture: destination, operation: .init(loadAction: .clear, storeAction: .store))], depthStencilAttachment: nil))
                pass.setViewport(viewport)
                pass.setRenderPipelineState(effectPipeline)
                pass.setFragmentBuffer(constants, offset: 0, slot: 5)
                pass.setResourceSet(.init(bindings: [
                    .init(binding: 0, shaderStages: .fragment, resource: .texture(texture)),
                    .init(binding: 1, shaderStages: .fragment, resource: .texture(motionTexture)),
                    .init(binding: 2, shaderStages: .fragment, resource: .texture(position)),
                    .init(binding: 3, shaderStages: .fragment, resource: .sampler(effects.linear)),
                    .init(binding: 4, shaderStages: .fragment, resource: .sampler(effects.nearest)),
                ]), index: 0)
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                pass.endRenderPass()
            }
            encode(copy: false, texture: output, destination: scratch,
                   viewport: Rect(x: 0, y: 0, width: Float(scratch.size.width), height: Float(scratch.size.height)))
            encode(copy: true, texture: scratch, destination: output, viewport: camera.viewport.rect)
            if notifiesCompletion, !overlays.hasOverlay, let drawable = target.outputTexture, drawable === output {
                command.addCompletedHandler { [drawable] in drawable.notifyRenderCompleted() }
            }
            if let metrics { command.addCompletedTimingHandler { metrics.record(pass: "cameraEffects", seconds: $0) } }
            submitted = command
        }
        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}

struct CameraEffects3DUniform: Sendable {
    var lens: Vector4
    var blur: Vector4
    var size: Vector4
    var rain: Vector4 = .zero
}

struct CameraEffects3DHistory: Sendable {
    var previousView = Transform3D.identity
    var previousViewProjection = Transform3D.identity
    var size = SizeInt.zero
    var frame = -1

    mutating func prepare(frame: Int, uniform: GlobalViewUniform, size: SizeInt) -> (previousView: Transform3D, previousViewProjection: Transform3D, reset: Bool) {
        let camera = uniform.viewMatrix.inverse
        let previous = previousView.inverse
        let reset = self.frame != frame - 1 || self.size != size || (camera.origin - previous.origin).length > 2
            || camera.z.xyz.normalized.dot(previous.z.xyz.normalized) < 0.5
        let result = (reset ? uniform.viewMatrix : previousView, reset ? uniform.viewProjectionMatrix : previousViewProjection, reset)
        previousView = uniform.viewMatrix
        previousViewProjection = uniform.viewProjectionMatrix
        self.frame = frame
        self.size = size
        return result
    }
}

struct CameraEffects3DViews: Resource {
    let linear: Sampler
    let nearest: Sampler
    var uniform = FrameUniformCache3D<CameraEffects3DUniform>()
    private var renderPipeline: RenderPipeline?
    private var scratches: [Entity.ID: RenderTexture] = [:]
    private var motion: [Entity.ID: (motion: RenderTexture, reactive: RenderTexture)] = [:]
    private var histories: [Entity.ID: CameraEffects3DHistory] = [:]
    private var retired: [[RenderTexture]] = []
    private(set) var frame = 0

    init(device: RenderDevice) {
        linear = device.createSampler(from: .init(minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped))
        nearest = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped))
    }

    mutating func pipeline(device: RenderDevice) -> RenderPipeline {
        if let renderPipeline { return renderPipeline }
        let shader = CorePipelineShaders.loadRequiredBundled(at: "Shaders/camera_effects_3d.glsl")
        var descriptor = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex), fragment: shader.asset.getShader(for: .fragment),
                                                  debugName: "Camera Effects 3D", backfaceCulling: false, depthPixelFormat: .none)
        descriptor.colorAttachments = [.init(format: .bgra8)]
        let result = device.createRenderPipeline(from: descriptor)
        renderPipeline = result
        return result
    }

    func hasScratch(view: Entity.ID) -> Bool { scratches[view] != nil }
    func hasMotion(view: Entity.ID) -> Bool { motion[view] != nil }

    mutating func retainViews(_ active: [Entity.ID]) {
        frame += 1
        for id in scratches.keys where !active.contains(id) { discard(view: id) }
        uniform.retainViews(active)
    }

    mutating func history(view: Entity.ID, uniform: GlobalViewUniform, size: SizeInt) -> (previousView: Transform3D, previousViewProjection: Transform3D, reset: Bool) {
        var history = histories[view] ?? CameraEffects3DHistory()
        let result = history.prepare(frame: frame, uniform: uniform, size: size)
        histories[view] = history
        return result
    }

    mutating func discardMotion(view: Entity.ID) {
        histories.removeValue(forKey: view)
        if let textures = motion.removeValue(forKey: view) { retire([textures.motion, textures.reactive]) }
    }

    mutating func discard(view: Entity.ID) {
        if let texture = scratches.removeValue(forKey: view) { retire([texture]) }
        discardMotion(view: view)
    }

    mutating func scratch(view: Entity.ID, like output: RenderTexture) -> RenderTexture {
        if let existing = scratches[view], existing.size == output.size { return existing }
        discard(view: view)
        let texture = RenderTexture(size: output.size, scaleFactor: output.scaleFactor, format: .bgra8, debugLabel: "3D Camera Effects Scratch")
        scratches[view] = texture
        return texture
    }

    mutating func motionTextures(view: Entity.ID, like output: RenderTexture) -> (motion: RenderTexture, reactive: RenderTexture) {
        if let existing = motion[view], existing.motion.size == output.size { return existing }
        discardMotion(view: view)
        let textures = (
            RenderTexture(size: output.size, scaleFactor: output.scaleFactor, format: .rgba_16f, debugLabel: "3D Camera Blur Motion"),
            RenderTexture(size: output.size, scaleFactor: output.scaleFactor, format: .bgra8, debugLabel: "3D Camera Blur Reactive")
        )
        motion[view] = textures
        return textures
    }

    private mutating func retire(_ textures: [RenderTexture]) {
        retired.append(textures)
        let limit = max(1, unsafe RenderEngine.configurations.maxFramesInFlight) + 1
        if retired.count > limit { retired.removeFirst(retired.count - limit) }
    }
}
