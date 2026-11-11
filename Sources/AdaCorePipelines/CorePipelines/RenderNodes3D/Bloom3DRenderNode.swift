import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// Builds the HDR bloom texture the environment composite adds before tone mapping.
///
/// The chain starts at half resolution with a soft-knee threshold on exposed luminance, halves down to a few
/// pixels, then adds each wider level back into the one above with additive blending. Cameras with bloom
/// disabled return immediately, record no GPU work and hold no textures.
public struct Bloom3DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.Bloom"

    @Query<Entity, Camera, RenderViewTarget, ExtractedCameraSource> private var views
    @Res<ExtractedEnvironment3D> private var environments
    @ResMut<Bloom3DViews> private var bloom
    @Res<RenderDeviceHandler> private var device
    @Res<Render3DPerformanceMetrics?> private var metrics
    @Res<AutoExposure3DViews> private var autoExposure

    public init() {}

    public func update(from world: World) {
        views.update(from: world)
        _environments.update(from: world)
        _bloom.update(from: world)
        _device.update(from: world)
        _metrics.update(from: world)
        _autoExposure.update(from: world)
        var activeViews: [Entity.ID] = []
        views.forEach { _, _, _, source in activeViews.append(source.entityId) }
        bloom.retainViews(activeViews)
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
            guard let environment = environments.environments[source.entityId],
                environment.postProcess.bloom.isEnabled, environment.postProcess.bloom.sanitized.intensity > 0,
                target.rendering3DUsesEnvironmentTargets, let sceneColor = target.sceneColor3DTexture
            else {
                bloom.discard(view: source.entityId)
                return
            }
            let settings = environment.postProcess.bloom.sanitized
            let levels = bloom.chain(view: source.entityId, source: sceneColor.size, scaleFactor: sceneColor.scaleFactor)
            let command = renderContext.commandQueue.makeCommandBuffer()
            command.label = "Bloom 3D"
            let exposure = environment.postProcess.exposureScale
            let automatic = environment.postProcess.autoExposure.isEnabled ? autoExposure.output(view: source.entityId) : nil
            var passIndex = 0
            func encode(source texture: RenderTexture, destination: RenderTexture, mode: Float, additive: Bool) {
                let constants = bloom.uniform.write(
                    Bloom3DUniform(
                        parameters: Vector4(mode, settings.threshold, max(settings.threshold * settings.softKnee, 0.0001), settings.scatter),
                        texel: Vector4(1 / Float(texture.size.width), 1 / Float(texture.size.height), exposure, automatic == nil ? 0 : 1)
                    ),
                    view: source.entityId,
                    pass: passIndex,
                    device: device.renderDevice
                )
                passIndex += 1
                let pass = command.beginRenderPass(RenderPassDescriptor(
                    label: "Bloom 3D",
                    colorAttachments: [.init(texture: destination, operation: .init(loadAction: additive ? .load : .clear, storeAction: .store), clearColor: .black)],
                    depthStencilAttachment: nil
                ))
                pass.setViewport(Rect(x: 0, y: 0, width: Float(destination.size.width), height: Float(destination.size.height)))
                pass.setRenderPipelineState(additive ? bloom.additivePipeline : bloom.replacePipeline)
                pass.setFragmentBuffer(constants, offset: 0, slot: 4)
                pass.setResourceSet(RenderResourceSet(bindings: [
                    .init(binding: 0, shaderStages: .fragment, resource: .texture(texture)),
                    .init(binding: 1, shaderStages: .fragment, resource: .sampler(bloom.sampler)),
                    .init(binding: 2, shaderStages: .fragment, resource: .texture(automatic ?? Texture2D.whiteTexture)),
                ]), index: 0)
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                pass.endRenderPass()
            }
            encode(source: sceneColor, destination: levels[0], mode: 0, additive: false)
            for level in 1..<levels.count {
                encode(source: levels[level - 1], destination: levels[level], mode: 1, additive: false)
            }
            for level in stride(from: levels.count - 2, through: 0, by: -1) {
                encode(source: levels[level + 1], destination: levels[level], mode: 2, additive: true)
            }
            if let metrics {
                command.addCompletedTimingHandler { metrics.record(pass: "bloom", seconds: $0) }
            }
            submitted = command
        }
        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }
}

struct Bloom3DUniform: Sendable {
    var parameters: Vector4
    var texel: Vector4
}

/// Per-camera bloom chains, pipelines and constants.
struct Bloom3DViews: Resource {
    /// Most levels in a chain; each halves the previous one.
    static let maximumLevels = 6

    private struct Chain {
        var size: SizeInt
        var levels: [RenderTexture]
    }

    let replacePipeline: RenderPipeline
    let additivePipeline: RenderPipeline
    let sampler: Sampler
    var uniform = FrameUniformCache3D<Bloom3DUniform>()
    private var chains: [Entity.ID: Chain] = [:]
    /// Replaced chains stay alive for the frames that may still be reading them.
    private var retired: [[RenderTexture]] = []

    init(device: RenderDevice) {
        let shader = CorePipelineShaders.loadRequiredBuiltin("bloom_3d")
        var descriptor = RenderPipelineDescriptor(
            vertex: shader.asset.requiredShader(for: .vertex),
            fragment: shader.asset.getShader(for: .fragment),
            debugName: "Bloom 3D",
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        descriptor.colorAttachments = [.init(format: .rgba_16f)]
        replacePipeline = device.createRenderPipeline(from: descriptor)
        descriptor.debugName = "Bloom 3D (additive)"
        descriptor.colorAttachments = [
            .init(
                format: .rgba_16f,
                isBlendingEnabled: true,
                sourceRGBBlendFactor: .one,
                sourceAlphaBlendFactor: .one,
                destinationAlphaBlendFactor: .one,
                destinationRGBBlendFactor: .one
            )
        ]
        additivePipeline = device.createRenderPipeline(from: descriptor)
        sampler = device.createSampler(from: .init(minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped))
    }

    /// The bloom result for `view`, valid only while that view's bloom ran this frame.
    func output(view: Entity.ID) -> RenderTexture? {
        chains[view]?.levels.first
    }

    mutating func retainViews(_ views: [Entity.ID]) {
        for view in chains.keys where !views.contains(view) {
            discard(view: view)
        }
        uniform.retainViews(views)
    }

    mutating func discard(view: Entity.ID) {
        guard let removed = chains.removeValue(forKey: view) else {
            return
        }
        retire(removed.levels)
    }

    /// Level sizes for a scene of `source` size: half resolution first, each next level half again, stopping at
    /// `maximumLevels` or once the smaller side is four pixels or less.
    static func levelSizes(for source: SizeInt) -> [SizeInt] {
        var sizes: [SizeInt] = []
        var width = max(1, (source.width + 1) / 2)
        var height = max(1, (source.height + 1) / 2)
        while sizes.count < maximumLevels {
            sizes.append(SizeInt(width: width, height: height))
            if min(width, height) <= 4 {
                break
            }
            width = max(1, (width + 1) / 2)
            height = max(1, (height + 1) / 2)
        }
        return sizes
    }

    /// Number of levels currently allocated for `view`; zero when the view has no bloom chain.
    func levelCount(view: Entity.ID) -> Int {
        chains[view]?.levels.count ?? 0
    }

    /// Returns the levels for a scene of `source` size, rebuilding them when the size changed.
    mutating func chain(view: Entity.ID, source: SizeInt, scaleFactor: Float) -> [RenderTexture] {
        if let existing = chains[view], existing.size == source {
            return existing.levels
        }
        if let replaced = chains[view] {
            retire(replaced.levels)
        }
        let levels = Self.levelSizes(for: source).enumerated().map { index, size in
            RenderTexture(size: size, scaleFactor: scaleFactor, format: .rgba_16f, debugLabel: "3D Bloom Level \(index)")
        }
        chains[view] = Chain(size: source, levels: levels)
        return levels
    }

    private mutating func retire(_ levels: [RenderTexture]) {
        retired.append(levels)
        let limit = max(1, unsafe RenderEngine.configurations.maxFramesInFlight) + 1
        if retired.count > limit {
            retired.removeFirst(retired.count - limit)
        }
    }
}
