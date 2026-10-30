import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// Meters the lit scene and adapts a per-camera exposure stored in a one-pixel texture.
///
/// The scene color is reduced through a 64 by 64 log-luminance meter and a 2x2 averaging chain to one pixel;
/// an adaptation pass then moves the stored exposure (in stops) toward the value that maps the metered average
/// to mid gray, at the configured speeds. Bloom and the environment composite read that texture. Cameras with
/// automatic exposure off record no GPU work and hold no textures.
public struct AutoExposure3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.AutoExposure"

    @Query<Entity, Camera, RenderViewTarget, ExtractedCameraSource> private var views
    @Res<ExtractedEnvironment3D> private var environments
    @ResMut<AutoExposure3DViews> private var exposure
    @Res<RenderDeviceHandler> private var device
    @Res<Render3DPerformanceMetrics?> private var metrics

    public init() {}

    public func update(from world: World) {
        views.update(from: world)
        _environments.update(from: world)
        _exposure.update(from: world)
        _device.update(from: world)
        _metrics.update(from: world)
        var activeViews: [Entity.ID] = []
        views.forEach { _, _, _, source in activeViews.append(source.entityId) }
        exposure.retainViews(activeViews)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }
        var submitted: CommandBuffer?
        views.forEach { entity, _, target, source in
            guard entity == view else {
                return
            }
            guard let environment = environments.environments[source.entityId], environment.postProcess.autoExposure.isEnabled,
                target.rendering3DUsesEnvironmentTargets, let sceneColor = target.sceneColor3DTexture,
                let normalRoughness = target.normalRoughness3DTexture
            else {
                exposure.discard(view: source.entityId)
                return
            }
            let settings = environment.postProcess.autoExposure.sanitized
            let state = exposure.prepare(view: source.entityId)
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "Auto Exposure 3D"
            var passIndex = 0
            func encode(mode: Float, destination: RenderTexture, source texture: Texture, auxiliary: Texture) {
                let constants = exposure.uniform.write(
                    AutoExposure3DUniform(
                        parameters: Vector4(mode, state.deltaTime, settings.speedUp, settings.speedDown),
                        limits: Vector4(settings.minimumEV, settings.maximumEV, state.reset ? 1 : 0, 0)
                    ),
                    view: source.entityId,
                    pass: passIndex,
                    device: device.renderDevice
                )
                passIndex += 1
                let pass = command.beginRenderPass(RenderPassDescriptor(
                    label: "Auto Exposure 3D",
                    colorAttachments: [.init(texture: destination, operation: .init(loadAction: .dontCare, storeAction: .store))],
                    depthStencilAttachment: nil
                ))
                pass.setViewport(Rect(x: 0, y: 0, width: Float(destination.size.width), height: Float(destination.size.height)))
                pass.setRenderPipelineState(exposure.pipeline)
                pass.setFragmentBuffer(constants, offset: 0, slot: 4)
                pass.setResourceSet(RenderResourceSet(bindings: [
                    .init(binding: 0, shaderStages: .fragment, resource: .texture(texture)),
                    .init(binding: 1, shaderStages: .fragment, resource: .texture(auxiliary)),
                    .init(binding: 2, shaderStages: .fragment, resource: .sampler(exposure.nearest)),
                    .init(binding: 3, shaderStages: .fragment, resource: .sampler(exposure.linear)),
                ]), index: 0)
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                pass.endRenderPass()
            }
            let levels = state.levels
            encode(mode: 0, destination: levels[0], source: sceneColor, auxiliary: normalRoughness)
            for level in 1..<levels.count {
                encode(mode: 1, destination: levels[level], source: levels[level - 1], auxiliary: levels[level - 1])
            }
            encode(mode: 2, destination: state.next, source: levels[levels.count - 1], auxiliary: state.previous)
            if let metrics {
                command.addCompletedTimingHandler { metrics.record(pass: "autoExposure", seconds: $0) }
            }
            submitted = command
        }
        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}

struct AutoExposure3DUniform: Sendable {
    var parameters: Vector4
    var limits: Vector4
}

/// Per-camera meter chains, adapted exposure state and pipelines for ``AutoExposure3DRenderNode``.
struct AutoExposure3DViews: Resource {
    /// Side lengths of the meter chain, from the 64 by 64 meter down to one pixel.
    static let meterSizes = [64, 32, 16, 8, 4, 2, 1]
    /// Longest frame step the adaptation will integrate, so a stall does not make exposure jump.
    static let maximumDeltaTime: Double = 0.25

    /// Resources the node needs for one frame of one view.
    struct Frame {
        var levels: [RenderTexture]
        var previous: RenderTexture
        var next: RenderTexture
        var deltaTime: Float
        var reset: Bool
    }

    private struct State {
        var levels: [RenderTexture]
        /// Ping-pong pair; `current` holds the exposure the consumers read.
        var pair: [RenderTexture]
        var current = 0
        var lastTime: Double?
        var initialized = false
    }

    let pipeline: RenderPipeline
    let nearest: Sampler
    let linear: Sampler
    var uniform = FrameUniformCache3D<AutoExposure3DUniform>()
    /// Source of monotonic time in seconds; replaceable so tests can drive adaptation.
    var clock: @Sendable () -> Double = { Time.absolute }
    private var states: [Entity.ID: State] = [:]
    private var retired: [[RenderTexture]] = []

    init(device: RenderDevice) {
        let shader = CorePipelineShaders.loadRequiredBundled(at: "Shaders/auto_exposure_3d.glsl")
        var descriptor = RenderPipelineDescriptor(
            vertex: shader.asset.requiredShader(for: .vertex),
            fragment: shader.asset.getShader(for: .fragment),
            debugName: "Auto Exposure 3D",
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        descriptor.colorAttachments = [.init(format: .rgba_16f)]
        pipeline = device.createRenderPipeline(from: descriptor)
        nearest = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped))
        linear = device.createSampler(from: .init(minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped))
    }

    /// The texture whose red plus green channels hold adapted exposure in stops, once the view has run.
    func output(view: Entity.ID) -> RenderTexture? {
        guard let state = states[view], state.initialized else {
            return nil
        }
        return state.pair[state.current]
    }

    mutating func retainViews(_ views: [Entity.ID]) {
        for view in states.keys where !views.contains(view) {
            discard(view: view)
        }
        uniform.retainViews(views)
    }

    mutating func discard(view: Entity.ID) {
        guard let removed = states.removeValue(forKey: view) else {
            return
        }
        retire(removed.levels + removed.pair)
    }

    /// Advances the view's clock and ping-pong index, creating textures on first use.
    mutating func prepare(view: Entity.ID) -> Frame {
        var state = states[view] ?? State(
            levels: Self.meterSizes.enumerated().map { index, size in
                RenderTexture(size: SizeInt(width: size, height: size), scaleFactor: 1, format: .rgba_16f, debugLabel: "3D Auto Exposure Meter \(index)")
            },
            pair: (0..<2).map { RenderTexture(size: SizeInt(width: 1, height: 1), scaleFactor: 1, format: .rgba_16f, debugLabel: "3D Auto Exposure State \($0)") }
        )
        let now = clock()
        let delta = state.lastTime.map { Float(min(max(now - $0, 0), Self.maximumDeltaTime)) } ?? 0
        state.lastTime = now
        let previous = state.pair[state.current]
        let next = state.pair[1 - state.current]
        let frame = Frame(levels: state.levels, previous: previous, next: next, deltaTime: delta, reset: !state.initialized)
        // The adaptation pass writes `next`, which becomes the exposure consumers read after this frame.
        state.current = 1 - state.current
        state.initialized = true
        states[view] = state
        return frame
    }

    private mutating func retire(_ textures: [RenderTexture]) {
        retired.append(textures)
        let limit = max(1, unsafe RenderEngine.configurations.maxFramesInFlight) + 1
        if retired.count > limit {
            retired.removeFirst(retired.count - limit)
        }
    }
}
