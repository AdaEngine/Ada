import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// Blurs surfaces away from the focus distance on the final display color.
///
/// Runs after the last color writer (SSR composite, FXAA or temporal resolve) and before debug views and debug
/// draw. It gathers from the output into a scratch texture and copies the result back, so it needs no extra
/// target for cameras that leave it off. A camera without depth of field, or one showing a full-screen debug
/// view, records no GPU work.
public struct DepthOfField3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.DepthOfField"

    @Query<Entity, Camera, RenderViewTarget, ExtractedCameraSource> private var views
    @Res<ExtractedEnvironment3D> private var environments
    @ResMut<DepthOfField3DViews> private var depthOfField
    @Res<RenderDeviceHandler> private var device
    @Res<Render3DPerformanceMetrics?> private var metrics
    @Res<ExtractedDebugLines3D> private var overlays
    private let notifiesCompletion: Bool

    public init(notifiesCompletion: Bool = true) { self.notifiesCompletion = notifiesCompletion }

    public func update(from world: World) {
        views.update(from: world)
        _environments.update(from: world)
        _depthOfField.update(from: world)
        _device.update(from: world)
        _metrics.update(from: world)
        _overlays.update(from: world)
        var activeViews: [Entity.ID] = []
        views.forEach { _, _, _, source in activeViews.append(source.entityId) }
        depthOfField.retainViews(activeViews)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }
        var submitted: CommandBuffer?
        views.forEach { entity, camera, target, source in
            guard entity == view else {
                return
            }
            guard let environment = environments.environments[source.entityId], environment.postProcess.depthOfField.changesImage,
                !environment.debugView.replacesFinalImage, let output = target.mainTexture,
                let position = target.viewPositionMetallic3DTexture
            else {
                depthOfField.discard(view: source.entityId)
                return
            }
            let settings = environment.postProcess.depthOfField.sanitized
            let scratch = depthOfField.scratch(view: source.entityId, like: output)
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "Depth Of Field 3D"
            var passIndex = 0
            func encode(mode: Float, source texture: Texture, destination: RenderTexture, viewport: Rect) {
                let constants = depthOfField.uniform.write(
                    DepthOfField3DUniform(
                        parameters: Vector4(mode, settings.focusDistance, settings.aperture, settings.maximumBlurRadius),
                        size: Vector4(1 / Float(output.size.width), 1 / Float(output.size.height), 0, 0)
                    ),
                    view: source.entityId,
                    pass: passIndex,
                    device: device.renderDevice
                )
                passIndex += 1
                let pass = command.beginRenderPass(RenderPassDescriptor(
                    label: "Depth Of Field 3D",
                    colorAttachments: [.init(texture: destination, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)],
                    depthStencilAttachment: nil
                ))
                pass.setViewport(viewport)
                pass.setRenderPipelineState(depthOfField.pipeline)
                pass.setFragmentBuffer(constants, offset: 0, slot: 4)
                pass.setResourceSet(RenderResourceSet(bindings: [
                    .init(binding: 0, shaderStages: .fragment, resource: .texture(texture)),
                    .init(binding: 1, shaderStages: .fragment, resource: .texture(position)),
                    .init(binding: 2, shaderStages: .fragment, resource: .sampler(depthOfField.linear)),
                    .init(binding: 3, shaderStages: .fragment, resource: .sampler(depthOfField.nearest)),
                ]), index: 0)
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                pass.endRenderPass()
            }
            encode(mode: 0, source: output, destination: scratch, viewport: Rect(x: 0, y: 0, width: Float(scratch.size.width), height: Float(scratch.size.height)))
            encode(mode: 1, source: scratch, destination: output, viewport: camera.viewport.rect)
            if notifiesCompletion, !overlays.hasOverlay, !environment.cameraEffectsWriteOutput, let drawable = target.outputTexture, drawable === output {
                command.addCompletedHandler { [drawable] in drawable.notifyRenderCompleted() }
            }
            if let metrics {
                command.addCompletedTimingHandler { metrics.record(pass: "depthOfField", seconds: $0) }
            }
            submitted = command
        }
        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}

struct DepthOfField3DUniform: Sendable {
    var parameters: Vector4
    var size: Vector4
}

/// The depth-of-field pipeline and a scratch texture per camera, created only while the effect runs.
struct DepthOfField3DViews: Resource {
    let pipeline: RenderPipeline
    let linear: Sampler
    let nearest: Sampler
    var uniform = FrameUniformCache3D<DepthOfField3DUniform>()
    private var scratchTextures: [Entity.ID: RenderTexture] = [:]
    private var retired: [RenderTexture] = []

    init(device: RenderDevice) {
        let shader = CorePipelineShaders.loadRequiredBundled(at: "Shaders/depth_of_field_3d.glsl")
        var descriptor = RenderPipelineDescriptor(
            vertex: shader.asset.requiredShader(for: .vertex),
            fragment: shader.asset.getShader(for: .fragment),
            debugName: "Depth Of Field 3D",
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        descriptor.colorAttachments = [.init(format: .bgra8)]
        pipeline = device.createRenderPipeline(from: descriptor)
        linear = device.createSampler(from: .init(minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped))
        nearest = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped))
    }

    /// Whether `view` currently holds a scratch texture.
    func hasScratch(view: Entity.ID) -> Bool {
        scratchTextures[view] != nil
    }

    mutating func retainViews(_ views: [Entity.ID]) {
        for view in scratchTextures.keys where !views.contains(view) {
            discard(view: view)
        }
        uniform.retainViews(views)
    }

    mutating func discard(view: Entity.ID) {
        if let removed = scratchTextures.removeValue(forKey: view) {
            retire(removed)
        }
    }

    /// A texture the size of `output`, rebuilt when the output size changes.
    mutating func scratch(view: Entity.ID, like output: RenderTexture) -> RenderTexture {
        if let existing = scratchTextures[view], existing.size == output.size {
            return existing
        }
        if let replaced = scratchTextures[view] {
            retire(replaced)
        }
        let texture = RenderTexture(size: output.size, scaleFactor: output.scaleFactor, format: .bgra8, debugLabel: "3D Depth Of Field Scratch")
        scratchTextures[view] = texture
        return texture
    }

    private mutating func retire(_ texture: RenderTexture) {
        retired.append(texture)
        let limit = max(1, unsafe RenderEngine.configurations.maxFramesInFlight) + 1
        if retired.count > limit {
            retired.removeFirst(retired.count - limit)
        }
    }
}
