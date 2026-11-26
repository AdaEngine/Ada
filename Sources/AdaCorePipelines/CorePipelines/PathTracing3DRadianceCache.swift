import AdaECS
import AdaRender
import Math

/// Counters from the GPU probes used to warm the world-space cache.
public struct PathTracingRadianceCacheCounters: Sendable {
    public let hits: UInt32
    public let misses: UInt32
    public let updates: UInt32
}

struct PathTracing3DCachePipelines: Sendable {
    let trace: any RenderPipeline
    let update: any ComputePipelineState

    static func make(device: RenderDevice) throws -> Self? {
        let path = "Shaders/path_tracing_3d.wesl"
        let features = ["ADA_PATH_TRACING_RAY_QUERY", "ADA_PATH_TRACING_CACHE"]
        let compute = try ShaderModule.createBuiltinVariant(at: path, from: .adaModule, defines: features + ["ADA_PATH_TRACING_CACHE_UPDATE"])
        guard let shader = compute.getShader(for: .compute),
              let update = device.createComputePipeline(from: .init(shader: shader, debugName: "Path tracing radiance cache update"))
        else { return nil }
        let module = try ShaderModule.createBuiltinVariant(at: path, from: .adaModule, defines: features)
        guard let vertex = module.getShader(for: .vertex), let fragment = module.getShader(for: .fragment) else {
            return nil
        }
        let trace = device.createRenderPipeline(
            from: .init(
                vertex: vertex,
                fragment: fragment,
                debugName: "World-space path tracing (radiance cache)",
                backfaceCulling: false,
                depthPixelFormat: .none,
                colorAttachments: [.init(format: .rgba_16f)]
            )
        )
        return Self(trace: trace, update: update)
    }
}

/// Fixed-budget radiance storage and scratch. The dispatch that consumes requests has one writer per slot.
struct PathTracing3DRadianceCache: Sendable {
    private static let cells = 16_384
    private static let probes = 4_096
    private static let workgroupSize = 64
    private static let movingLifetime = 12
    private static let lightingTransitionFrames = 48
    // Keep in sync with RadianceCacheCell and RadianceCacheRequest in path_tracing_radiance_cache.wesl.
    private static let cellStride = 112
    private static let requestStride = 64
    static let counterBytes = 3 * MemoryLayout<UInt32>.stride
    static let byteCount = cells * (2 * cellStride + requestStride) + counterBytes

    private let cellsA: any Buffer
    private let cellsB: any Buffer
    private let requests: any Buffer
    let counters: any Buffer
    private var current = 0
    private var motionFramesRemaining = 0
    private var lightingFramesRemaining = 0
    private var lightingDigest: UInt64?
    var digest: UInt64?

    var readable: any Buffer { current == 0 ? cellsA : cellsB }
    private var writable: any Buffer { current == 0 ? cellsB : cellsA }

    init(device: RenderDevice) {
        let size = Self.cells * Self.cellStride
        cellsA = device.createBuffer(label: "Path tracing radiance cells A", length: size, options: .storagePrivate)
        cellsB = device.createBuffer(label: "Path tracing radiance cells B", length: size, options: .storagePrivate)
        requests = device.createBuffer(label: "Path tracing radiance requests", length: Self.cells * Self.requestStride, options: .storagePrivate)
        counters = device.createBuffer(label: "Path tracing radiance diagnostic counters", length: Self.counterBytes, options: .storagePrivate)
    }

    mutating func movingLifetime(objectsMoved: Bool) -> Float {
        // Stay in the short-lifetime mode until unrefreshed probes from before motion have expired.
        motionFramesRemaining = objectsMoved ? Self.movingLifetime + 1 : max(0, motionFramesRemaining - 1)
        return motionFramesRemaining > 0 ? Float(Self.movingLifetime) : 0
    }

    mutating func lightingTransition(digest: UInt64, resets: Bool) -> Bool {
        if resets {
            lightingFramesRemaining = 0
        } else if lightingDigest != digest {
            lightingFramesRemaining = Self.lightingTransitionFrames
        } else {
            lightingFramesRemaining = max(0, lightingFramesRemaining - 1)
        }
        lightingDigest = digest
        return lightingFramesRemaining > 0
    }

    mutating func encode(
        pass: any ComputeCommandEncoder,
        pipeline: any ComputePipelineState,
        sceneBindings: [ComputeResourceSet.Binding],
        constants: PathTracing3DUniform,
        view: Entity.ID,
        device: RenderDevice,
        uniforms: inout FrameUniformCache3D<PathTracing3DUniform>
    ) {
        let bindings = sceneBindings + [
            ComputeResourceSet.Binding(binding: 18, resource: .buffer(readable)),
            .init(binding: 19, resource: .buffer(writable)),
            .init(binding: 20, resource: .buffer(requests)),
            .init(binding: 21, resource: .buffer(counters)),
        ]
        pass.setComputePipelineState(pipeline)
        pass.setResourceSet(.init(bindings: bindings), index: 0)
        var uniform = constants
        for step in 0..<3 {
            uniform.frame.y = Float(6 + step)
            let buffer = uniforms.write(uniform, view: view, pass: 100 + step, device: device)
            guard let storage = buffer.buffer else {
                return
            }
            pass.setResourceSet(.init(bindings: [.init(binding: 4, resource: .buffer(storage))]), index: 0)
            let threadCount = step == 1 ? Self.probes : Self.cells
            pass.dispatch(threadgroups: SIMD3(threadCount / Self.workgroupSize, 1, 1))
        }
        current = 1 - current
    }
}

extension PathTracing3DViews {
    mutating func encodeRadianceCache(
        entry: inout Entry,
        settings: PathTracing3D,
        constants: inout PathTracing3DUniform,
        digest: FrameDigest3D,
        lightingDigest: UInt64,
        objectsMoved: Bool,
        bindings: [RenderResourceSet.Binding],
        view: Entity.ID,
        device: RenderDevice,
        command: CommandBuffer,
        hasRayQueries: Bool
    ) -> (any RenderPipeline)? {
        let interactive = settings.transport == .interactive
        entry.status.radianceCache = interactive ? "uncached" : "disabled"
        entry.status.radianceCacheBytes = 0
        entry.status.radianceCacheFallback = nil
        guard interactive, settings.radianceCache else {
            entry.radianceCache = nil
            return nil
        }
        guard hasRayQueries, constants.hybrid.x > 0.5, settings.maximumBounces > 2, device.supportsComputePasses else {
            entry.radianceCache = nil
            entry.status.radianceCacheFallback = "The radiance cache needs Vulkan ray queries, a G-buffer first hit, and at least three surface interactions"
            return nil
        }
        guard let pipelines = readyCachePipelines(device),
              let pass = command.beginComputePass(.init(label: "Path tracing radiance cache"))
        else {
            entry.radianceCache = nil
            entry.status.radianceCacheFallback = radianceCacheFailure ?? "The radiance cache pipelines are preparing"
            return nil
        }

        var digest = digest
        digest.combine(constants.zenith)
        digest.combine(constants.horizon)
        digest.combine(constants.ground)
        digest.combine(constants.sky)
        digest.combine(constants.frame.w)
        digest.combine(constants.trace.x)
        digest.combine(constants.trace.y)
        digest.combine(constants.trace.z)
        digest.combine(UInt64(settings.maximumBounces))
        digest.combine(settings.radianceCacheDiagnostics ? UInt64(1) : 0)
        var cache = entry.radianceCache ?? PathTracing3DRadianceCache(device: device)
        let resets = cache.digest != digest.value
        cache.digest = digest.value
        constants.hybrid.w = cache.movingLifetime(objectsMoved: objectsMoved && !resets)
        var uniform = constants
        let transitioning = cache.lightingTransition(digest: lightingDigest, resets: resets)
        uniform.transport.z = resets ? 1 : (transitioning ? -1 : 0)
        uniform.transport.w = settings.radianceCacheDiagnostics ? 1 : 0
        let computeBindings: [ComputeResourceSet.Binding] = bindings.compactMap { entry in
            let resource: ComputeResourceSet.Binding.Resource
            switch entry.resource {
            case let .texture(texture):
                resource = .sampledTexture(texture, mipLevel: nil)
            case let .sampler(sampler):
                resource = .sampler(sampler)
            case let .accelerationStructure(structure):
                resource = .accelerationStructure(structure)
            case .uniformBuffer, .storageBuffer:
                return nil
            }
            return .init(binding: entry.binding, resource: resource)
        }
        cache.encode(
            pass: pass,
            pipeline: pipelines.update,
            sceneBindings: computeBindings,
            constants: uniform,
            view: view,
            device: device,
            uniforms: &uniforms
        )
        pass.endComputePass()
        entry.radianceCache = cache
        entry.status.radianceCache = "world-space"
        entry.status.radianceCacheBytes = PathTracing3DRadianceCache.byteCount
        entry.status.radianceCacheResets = (entry.status.radianceCacheResets ?? 0) + (resets ? 1 : 0)
        return pipelines.trace
    }
}
