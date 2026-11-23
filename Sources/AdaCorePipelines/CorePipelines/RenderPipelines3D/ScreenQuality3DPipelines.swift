import AdaAssets
import AdaECS
import AdaRender
import Math

struct ScreenQuality3DPipelines: Resource {
    private var ao: RenderPipeline?
    private var aa: RenderPipeline?
    private var cortaoPyramid: (any ComputePipelineState)?
    private var cortaoPyramidAttempted = false
    private var cortaoOcclusion: RenderPipeline?
    private var cortaoTemporal: RenderPipeline?
    private var cortaoTable: Texture2D?
    let nearest: Sampler
    let linear: Sampler

    init(device: RenderDevice) {
        nearest = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped))
        linear = device.createSampler(from: .init(minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped))
    }

    mutating func aoPipeline(device: RenderDevice) -> RenderPipeline {
        if let ao {
            return ao
        }
        let shader = CorePipelineShaders.loadRequiredBuiltin("ssao_3d")
        let pipeline = make(shader, label: "SSAO 3D", device: device)
        ao = pipeline
        return pipeline
    }

    /// CORTAO main pass (fragment). Reads the pyramid built by ``cortaoPyramidPipeline(device:)``.
    mutating func cortaoPipeline(device: RenderDevice) -> RenderPipeline {
        if let cortaoOcclusion {
            return cortaoOcclusion
        }
        let shader = CorePipelineShaders.loadRequiredBuiltin("cortao_3d")
        let pipeline = make(shader, label: "CORTAO 3D", device: device)
        cortaoOcclusion = pipeline
        return pipeline
    }

    /// CORTAO pyramid build (compute), or nil when the device cannot run compute passes.
    mutating func cortaoPyramidPipeline(device: RenderDevice) -> (any ComputePipelineState)? {
        if cortaoPyramidAttempted {
            return cortaoPyramid
        }
        cortaoPyramidAttempted = true
        guard device.supportsComputePasses,
              let shader = CorePipelineShaders.loadRequiredBuiltin("cortao_pyramid_3d").asset.getShader(for: .compute) else {
            return nil
        }
        cortaoPyramid = device.createComputePipeline(from: ComputePipelineDescriptor(shader: shader, debugName: "CORTAO Pyramid"))
        return cortaoPyramid
    }

    /// CORTAO temporal accumulation. Renders into an RGBA16F history target and an R32F history-length target.
    mutating func cortaoTemporalPipeline(device: RenderDevice) -> RenderPipeline {
        if let cortaoTemporal {
            return cortaoTemporal
        }
        let shader = CorePipelineShaders.loadRequiredBuiltin("cortao_temporal_3d")
        let pipeline = make(shader, label: "CORTAO Temporal", formats: [.rgba_16f, .r32f], device: device)
        cortaoTemporal = pipeline
        return pipeline
    }

    /// Ray hit masks for the CORTAO main pass, generated on first use.
    mutating func cortaoOccluderTable() -> Texture2D {
        if let cortaoTable {
            return cortaoTable
        }
        let table = CortaoOccluderTable.makeTexture()
        cortaoTable = table
        return table
    }

    mutating func aaPipeline(device: RenderDevice) -> RenderPipeline {
        if let aa {
            return aa
        }
        let shader = CorePipelineShaders.loadRequiredBuiltin("fxaa_3d")
        let pipeline = make(shader, label: "FXAA 3D", device: device)
        aa = pipeline
        return pipeline
    }

    private func make(
        _ shader: AssetHandle<ShaderModule>, label: String, formats: [PixelFormat] = [.bgra8], device: RenderDevice
    ) -> RenderPipeline {
        var descriptor = RenderPipelineDescriptor(
            vertex: shader.asset.requiredShader(for: .vertex),
            fragment: shader.asset.getShader(for: .fragment),
            debugName: label,
            backfaceCulling: false,
            depthPixelFormat: .none
        )
        descriptor.colorAttachments = formats.map { .init(format: $0) }
        return device.createRenderPipeline(from: descriptor)
    }
}

struct SSAO3DUniform: Sendable {
    var projection: Transform3D
    var parameters: Vector4
    var pass: Vector4
}

/// Reprojection constants for the CORTAO temporal pass.
struct CortaoTemporalUniform: Sendable {
    /// Previous view-projection times inverse current view.
    var reprojection: Transform3D
    /// Current view times inverse previous view, to rotate view-space directions out of the history.
    var viewRotation: Transform3D
    var parameters: Vector4
}

/// Accumulated CORTAO occlusion of one view: two ping-pong targets holding (occlusion, view depth).
struct CortaoHistory {
    var targets: [RenderTexture]
    /// Frames of history behind each pixel of the matching target, so new and disoccluded pixels converge quickly.
    var ages: [RenderTexture]
    var readIndex = 0
    var previousViewProjection: Transform3D
    var previousViewMatrix: Transform3D
    var isValid = false
    var frame: UInt32 = 0
    /// Whether the history channels hold a bent normal. Toggling it would blend unrelated data, so it restarts accumulation.
    var hasBentNormals = false
}

/// What the node needs for one frame of temporal accumulation.
struct CortaoTemporalFrame {
    var read: RenderTexture
    var write: RenderTexture
    var readAge: RenderTexture
    var writeAge: RenderTexture
    var previousViewProjection: Transform3D
    var previousViewMatrix: Transform3D
    var isValid: Bool
    var frame: UInt32
}

struct ScreenQuality3DScratch: Resource {
    /// Mip levels of the CORTAO pyramid. Level 0 is the full-resolution G-buffer copy. Targets need at least 8 pixels per side.
    static let cortaoLevelCount = 4

    var ao = FrameUniformCache3D<SSAO3DUniform>()
    var cortao = FrameUniformCache3D<SSAO3DUniform>()
    var cortaoTemporal = FrameUniformCache3D<CortaoTemporalUniform>()
    var aa = FrameUniformCache3D<Vector4>()
    private var cortaoHistories: [Entity.ID: CortaoHistory] = [:]
    private var cortaoPyramids: [Entity.ID: RenderTexture] = [:]
    /// Views whose filtered AO target holds a bent normal this frame. Written by the AO node, read by later passes.
    private(set) var bentNormalViews: Set<Entity.ID> = []

    mutating func setBentNormals(view: Entity.ID, _ produced: Bool) {
        if produced { bentNormalViews.insert(view) } else { bentNormalViews.remove(view) }
    }

    /// Frees the CORTAO targets of a view that does not use them this frame (another technique, AO off, or no
    /// accumulation) so they are neither kept allocated nor read stale when CORTAO returns.
    mutating func releaseCortao(view: Entity.ID, keepPyramid: Bool = false, keepHistory: Bool = false) {
        if !keepPyramid { cortaoPyramids[view] = nil }
        if !keepHistory { cortaoHistories[view] = nil }
    }

    mutating func retainCortaoViews(_ views: [Entity.ID]) {
        cortao.retainViews(views)
        cortaoTemporal.retainViews(views)
        bentNormalViews = bentNormalViews.filter { views.contains($0) }
        if cortaoHistories.keys.contains(where: { !views.contains($0) }) {
            cortaoHistories = cortaoHistories.filter { views.contains($0.key) }
        }
        if cortaoPyramids.keys.contains(where: { !views.contains($0) }) {
            cortaoPyramids = cortaoPyramids.filter { views.contains($0.key) }
        }
    }

    /// Depth/normal pyramid for a view: one texture with ``cortaoLevelCount`` mips, recreated when the G-buffer size changes.
    mutating func cortaoPyramid(view: Entity.ID, size: SizeInt, scale: Float) -> RenderTexture {
        if let existing = cortaoPyramids[view], existing.size == size {
            return existing
        }
        let pyramid = RenderTexture(
            size: size,
            scaleFactor: scale,
            format: .rgba_16f,
            debugLabel: "3D CORTAO Pyramid",
            usage: [.read, .storage],
            mipLevelCount: Self.cortaoLevelCount
        )
        cortaoPyramids[view] = pyramid
        return pyramid
    }

    /// Starts a frame of accumulation: returns the history to read and the target to write, then makes the written
    /// target the next frame's history. A size change restarts accumulation.
    mutating func advanceCortaoHistory(
        view: Entity.ID,
        size: SizeInt,
        scale: Float,
        viewProjection: Transform3D,
        viewMatrix: Transform3D,
        bentNormals: Bool
    ) -> CortaoTemporalFrame {
        var current: CortaoHistory
        if let existing = cortaoHistories[view], existing.targets.first?.size == size {
            current = existing
        } else {
            current = CortaoHistory(
                targets: (0..<2).map {
                    RenderTexture(size: size, scaleFactor: scale, format: .rgba_16f, debugLabel: "3D CORTAO History \($0)")
                },
                ages: (0..<2).map {
                    RenderTexture(size: size, scaleFactor: scale, format: .r32f, debugLabel: "3D CORTAO History Length \($0)")
                },
                previousViewProjection: viewProjection,
                previousViewMatrix: viewMatrix
            )
        }
        if current.hasBentNormals != bentNormals {
            current.isValid = false
            current.hasBentNormals = bentNormals
        }
        let frame = CortaoTemporalFrame(
            read: current.targets[current.readIndex],
            write: current.targets[1 - current.readIndex],
            readAge: current.ages[current.readIndex],
            writeAge: current.ages[1 - current.readIndex],
            previousViewProjection: current.previousViewProjection,
            previousViewMatrix: current.previousViewMatrix,
            isValid: current.isValid,
            frame: current.frame
        )
        current.readIndex = 1 - current.readIndex
        current.previousViewProjection = viewProjection
        current.previousViewMatrix = viewMatrix
        current.isValid = true
        current.frame &+= 1
        cortaoHistories[view] = current
        return frame
    }
}
