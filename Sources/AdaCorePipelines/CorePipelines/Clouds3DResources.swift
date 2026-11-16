//
//  Clouds3DResources.swift
//  AdaEngine
//

import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import Math

/// Per-quality cost of the clouds. `low` has no raymarch: it shades one 2D layer, so it takes no view or light steps.
struct Clouds3DTier: Equatable, Sendable {
    var viewSteps: Int
    var lightSteps: Int
    /// Width and height of the cloud target relative to the frame. 0.5 is a quarter of the pixels.
    var resolutionScale: Float
    /// Whether the cloud is a shaded 2D layer instead of a raymarched volume.
    var isLayer: Bool

    static func tier(for quality: CloudQuality3D) -> Self {
        switch quality {
        case .low: Self(viewSteps: 0, lightSteps: 0, resolutionScale: 0.4, isLayer: true)
        case .medium: Self(viewSteps: 32, lightSteps: 4, resolutionScale: 0.5, isLayer: false)
        case .high: Self(viewSteps: 64, lightSteps: 6, resolutionScale: 0.7071, isLayer: false)
        }
    }

    func size(for fullSize: SizeInt) -> SizeInt {
        SizeInt(width: max(1, Int(Float(fullSize.width) * resolutionScale)), height: max(1, Int(Float(fullSize.height) * resolutionScale)))
    }
}

/// Uniform block of the cloud march. Mirrors `Clouds3DUniform` in `clouds_march_3d.wesl`.
struct Clouds3DUniform: Sendable {
    var shape: Vector4
    var layer: Vector4
    var wind: Vector4
    var frame: Vector4
    var previousViewProjection: Transform3D

    /// `clouds` must already be sanitized. `time` is in seconds.
    init(clouds: VolumetricClouds3D, tier: Clouds3DTier, time: Float, frame: Int, reset: Bool, previousViewProjection: Transform3D) {
        shape = Vector4(clouds.coverage, clouds.density, clouds.cloudType, clouds.detailScale)
        layer = Vector4(clouds.baseAltitudeMeters, clouds.thicknessMeters, clouds.lightingScale, clouds.ambientScale)
        wind = Vector4(
            clouds.windDirection.x * clouds.windSpeed * time, clouds.windDirection.y * clouds.windSpeed * time,
            Float(tier.viewSteps), Float(tier.lightSteps)
        )
        self.frame = Vector4(Float(frame % 16), reset ? 1 : 0, 0, 0)
        self.previousViewProjection = previousViewProjection
    }
}

/// Uniform block of the resolve pass. Mirrors `CloudResolveUniform` in `clouds_resolve_3d.wesl`.
struct CloudResolveUniform: Sendable {
    var previousViewProjection: Transform3D
    var parameters: Vector4

    /// Weight of last frame's result when it is reused.
    static let historyWeight: Float = 0.9

    init(clouds: VolumetricClouds3D, reset: Bool, previousViewProjection: Transform3D) {
        self.previousViewProjection = previousViewProjection
        parameters = Vector4(Self.historyWeight, reset ? 1 : 0, clouds.baseAltitudeMeters, clouds.thicknessMeters)
    }
}

/// What forces a camera to build new cloud targets. A change of tier or size does; a change of look (coverage, density,
/// seed, wind) does not: the history simply blends toward the new clouds over a few frames.
struct Clouds3DKey: Equatable, Sendable {
    var tier: Clouds3DTier
    var size: SizeInt
}

/// The textures and decisions for one camera's cloud frame.
struct Clouds3DFrame {
    let current: RenderTexture
    let read: RenderTexture
    let write: RenderTexture
    /// The fixed texture the composite reads. The resolve pass writes the same result to it and to `write`.
    let output: RenderTexture
    let reset: Bool
    let frameIndex: Int
    let previousViewProjection: Transform3D
}

/// Per-camera cloud targets and history bookkeeping. Holds nothing for a camera that stops using clouds.
struct Clouds3DViewStore {
    private struct Entry {
        var current: RenderTexture
        var history: [RenderTexture]
        var output: RenderTexture
        var key: Clouds3DKey
        var frameIndex = 0
        var readIndex = 0
        var previousViewProjection: Transform3D
        var position: Vector3
        var forward: Vector3
    }

    private var entries: [Entity.ID: Entry] = [:]
    private var retired: [(texture: RenderTexture, age: Int)] = []

    var viewCount: Int { entries.count }

    /// Bytes the cloud targets of every view hold on the GPU (`rgba_16f`, 8 bytes per texel, four textures per view).
    var memoryBytes: Int {
        entries.values.reduce(0) { total, entry in
            total + ([entry.current, entry.output] + entry.history).reduce(0) { $0 + $1.size.width * $1.size.height * 8 }
        }
    }

    /// Textures waiting for the frames in flight that may still read them.
    var retiredCount: Int { retired.count }

    /// The texture the composite reads for `view`. It is the same object for the life of the targets, so a copy of the store
    /// taken before this frame's `begin` still points at the texture the resolve pass fills this frame.
    func output(view: Entity.ID) -> RenderTexture? {
        entries[view]?.output
    }

    /// Ends one frame for retirement purposes: textures retired more than a frame-in-flight ago are released.
    mutating func advanceFrame() {
        let limit = max(1, unsafe RenderEngine.configurations.maxFramesInFlight) + 1
        retired = retired.map { ($0.texture, $0.age + 1) }.filter { $0.age <= limit }
    }

    /// Starts a frame: creates or recreates targets when the size, tier or settings changed, decides whether to reuse the
    /// history, and swaps the history textures.
    mutating func begin(
        view: Entity.ID, key: Clouds3DKey, position: Vector3, forward: Vector3, viewProjection: Transform3D
    ) -> Clouds3DFrame {
        var reset = false
        var entry: Entry
        if let existing = entries[view], existing.key == key {
            entry = existing
            let jump = (position - existing.position).length
            if jump > 3_000 || existing.forward.dot(forward) < 0.3 { reset = true }
        } else {
            if let existing = entries[view] { retire(existing) }
            func texture(_ label: String) -> RenderTexture {
                RenderTexture(size: key.size, scaleFactor: 1, format: .rgba_16f, debugLabel: label)
            }
            entry = Entry(
                current: texture("Cloud March"), history: [texture("Cloud History A"), texture("Cloud History B")],
                output: texture("Cloud Display"), key: key,
                previousViewProjection: viewProjection, position: position, forward: forward
            )
            reset = true
        }
        let read = entry.history[entry.readIndex]
        let write = entry.history[1 - entry.readIndex]
        let frame = Clouds3DFrame(
            current: entry.current, read: read, write: write, output: entry.output, reset: reset, frameIndex: entry.frameIndex,
            previousViewProjection: reset ? viewProjection : entry.previousViewProjection
        )
        entry.frameIndex += 1
        entry.readIndex = 1 - entry.readIndex
        entry.previousViewProjection = viewProjection
        entry.position = position
        entry.forward = forward
        entries[view] = entry
        return frame
    }

    mutating func discard(view: Entity.ID) {
        guard let removed = entries.removeValue(forKey: view) else {
            return
        }
        retire(removed)
    }

    mutating func retainViews(_ views: [Entity.ID]) {
        for view in entries.keys where !views.contains(view) {
            discard(view: view)
        }
    }

    /// A frame still in flight may read the textures, so keep them alive until `advanceFrame` has run enough times.
    private mutating func retire(_ entry: Entry) {
        retired.append(contentsOf: ([entry.current, entry.output] + entry.history).map { ($0, 0) })
    }
}

/// The cloud pipelines, the shared noise and the per-camera targets, created at startup.
struct Clouds3DViews: Resource {
    let marchPipeline: RenderPipeline
    let layerPipeline: RenderPipeline
    let resolvePipeline: RenderPipeline
    let noisePipelines: Clouds3DNoisePipelines
    let sampler: Sampler
    var noise = Clouds3DNoiseCache()
    var store = Clouds3DViewStore()
    var marchUniform = FrameUniformCache3D<Clouds3DUniform>()
    var resolveUniform = FrameUniformCache3D<CloudResolveUniform>()
    var atmosphereUniform = FrameUniformCache3D<Atmosphere3DUniform>()

    init(device: RenderDevice) {
        func pipeline(_ name: String, targets: Int = 1) -> RenderPipeline {
            let shader = CorePipelineShaders.loadRequiredBuiltin("clouds_\(name)_3d")
            var descriptor = RenderPipelineDescriptor(
                vertex: shader.asset.requiredShader(for: .vertex),
                fragment: shader.asset.getShader(for: .fragment),
                debugName: "Clouds \(name)",
                backfaceCulling: false,
                depthPixelFormat: .none
            )
            descriptor.colorAttachments = (0..<targets).map { _ in .init(format: .rgba_16f) }
            return device.createRenderPipeline(from: descriptor)
        }
        marchPipeline = pipeline("march")
        layerPipeline = pipeline("layer")
        resolvePipeline = pipeline("resolve", targets: 2)
        noisePipelines = Clouds3DNoisePipelines(device: device)
        sampler = device.createSampler(from: .init(minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped))
    }

    /// The resolved cloud texture of `view`, if clouds ran for it this frame.
    func output(view: Entity.ID) -> RenderTexture? {
        store.output(view: view)
    }

    mutating func retainViews(_ views: [Entity.ID]) {
        store.retainViews(views)
        marchUniform.retainViews(views)
        resolveUniform.retainViews(views)
        atmosphereUniform.retainViews(views)
    }

    mutating func discard(view: Entity.ID) {
        store.discard(view: view)
    }

    /// Releases textures that frames in flight can no longer read.
    mutating func advanceFrame() {
        store.advanceFrame()
        noise.advanceFrame()
    }

    var memoryBytes: Int { store.memoryBytes + noise.memoryBytes }
}
