import AdaAssets
import AdaECS
import AdaRender
import Foundation
import Math
import Synchronization

/// Static world-space hit points of uniformly distributed rays from a probe grid.
/// Runtime lights/shadows relight these surfaces independently of camera visibility.
public struct ProbeTransport3D: Asset, Sendable {
    public var assetMetaInfo: AssetMetaInfo?
    public let origin: Vector3
    public let spacing: Vector3
    public let counts: [Int]
    public let samples: Int
    public let surfaceBounds: AABB
    public let positions: Texture2D
    public let normals: Texture2D
    public let albedo: Texture2D

    public init(origin: Vector3, spacing: Vector3, counts: [Int], samples: Int,
        positions: Texture2D, normals: Texture2D, albedo: Texture2D, surfaceBounds: AABB? = nil) throws {
        let bounds = surfaceBounds ?? AABB(center:origin,halfExtents:Vector3.one*100)
        guard Self.valid(origin: origin, spacing: spacing, counts: counts, samples: samples),
            LocalLighting3DMath.isFinite(bounds.center), LocalLighting3DMath.isFinite(bounds.halfExtents),
            min(bounds.halfExtents.x,min(bounds.halfExtents.y,bounds.halfExtents.z)) >= 0,
            [positions, normals, albedo].allSatisfy({ $0.size == SizeInt(width: counts[0]*samples, height: counts[1]*counts[2]) })
        else { throw AssetError.message("Invalid probe transport layout") }
        self.origin = origin; self.spacing = spacing; self.counts = counts; self.samples = samples
        self.positions = positions; self.normals = normals; self.albedo = albedo
        self.surfaceBounds = bounds
    }
    static func valid(origin: Vector3, spacing: Vector3, counts: [Int], samples: Int) -> Bool {
        IrradianceProbeGrid3D.valid(origin: origin, spacing: spacing, counts: counts, resolution: 8)
            && [32,64,128,256].contains(samples) && counts[0]*samples <= 4096
    }
    public func matches(_ grid: IrradianceProbeGrid3D) -> Bool {
        origin == grid.origin && spacing == grid.spacing && counts == grid.counts
    }
    public init(from decoder: any AssetDecoder) async throws {
        struct Manifest: Decodable {
            var version: Int; var encoding: String; var origin: Vector3; var spacing: Vector3; var counts: [Int]; var samples: Int
            var positions: BakedHDRMap3D; var normals: BakedHDRMap3D; var albedo: BakedHDRMap3D
            var surfaceBounds: AABB
        }
        let m = try decoder.decode(Manifest.self)
        guard m.version == 1, m.encoding == "fibonacci-sphere-surface-transport-v1",
            Self.valid(origin: m.origin, spacing: m.spacing, counts: m.counts, samples: m.samples),
            [m.positions,m.normals,m.albedo].allSatisfy({ $0.width == m.counts[0]*m.samples && $0.height == m.counts[1]*m.counts[2] })
        else { throw AssetError.message("Invalid probe transport manifest") }
        let dir = decoder.assetMeta.filePath.deletingLastPathComponent()
        try self.init(origin: m.origin, spacing: m.spacing, counts: m.counts, samples: m.samples,
            positions: m.positions.load(in: dir, signed: true), normals: m.normals.load(in: dir, signed: true), albedo: m.albedo.load(in: dir),
            surfaceBounds:m.surfaceBounds)
    }
    public func encodeContents(with _: any AssetEncoder) async throws { throw AssetError.message("Use Tools/3DAssets/bake_probe_transport.py") }
    public static func extensions() -> [String] { ["proberays"] }
}

public struct DynamicIrradianceSettings3D: Codable, Sendable {
    public var transport: AssetHandle<ProbeTransport3D>
    /// Round-robin probe updates per rendered frame; independent of the camera frustum.
    public var probesPerFrame: Int
    /// Previous value retained when a probe is refreshed. Zero gives immediate replacement.
    public var historyWeight: Float
    public var intensity: Float
    public init(transport: AssetHandle<ProbeTransport3D>, probesPerFrame: Int = 64, historyWeight: Float = 0.15, intensity: Float = 1) {
        self.transport = transport; self.probesPerFrame = probesPerFrame; self.historyWeight = historyWeight; self.intensity = intensity
    }
}

public final class Render3DDynamicGIStatistics: Resource, Sendable {
    public struct Snapshot: Codable, Sendable {
        public var frames = 0
        public var probeCount = 0
        public var updatedProbes = 0
        public var lightCount = 0
        public var sweeps = 0
    }
    private let state = Mutex<[String: Snapshot]>([:])
    public init() {}
    func record(view: Entity.ID, count: Int, updated: Int, lights: Int, wrapped: Bool) {
        state.withLock { state in
            let key = "\(view)"
            var s = state[key] ?? Snapshot()
            s.frames += 1; s.probeCount = count; s.updatedProbes = updated; s.lightCount = lights
            if wrapped { s.sweeps += 1 }; state[key] = s
        }
    }
    func retain(_ active: [Entity.ID]) {
        state.withLock { state in
            for key in state.keys where !active.contains(where: { "\($0)" == key }) { state.removeValue(forKey: key) }
        }
    }
    func discard(view: Entity.ID) { state.withLock { _ = $0.removeValue(forKey:"\(view)") } }
    public var snapshots: [String: Snapshot] { state.withLock { $0 } }
}

struct DynamicIrradiance3DUniform: Sendable {
    var grid: Vector4 // nx, ny, nz, samples
    var update: Vector4 // cursor, budget, reset, light count
    var blend: Vector4 // history weight, intensity
}

struct DynamicIrradiance3DViews: Resource {
    struct Entry {
        var identity: ObjectIdentifier
        var pair: [RenderTexture]
        var index = 0
        var cursor = 0
        var initialized = false
        var output: RenderTexture { pair[index] }
    }
    var entries: [Entity.ID: Entry] = [:]
    var uniforms = FrameUniformCache3D<DynamicIrradiance3DUniform>()
    var pipeline: (any RenderPipeline)?
    var nearest: (any Sampler)?
    mutating func getPipeline(_ device: RenderDevice) -> any RenderPipeline {
        if let pipeline { return pipeline }
        let shader = CorePipelineShaders.loadRequiredBundled(at: "Shaders/dynamic_irradiance_3d.glsl")
        var descriptor = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex), fragment: shader.asset.getShader(for: .fragment),
            debugName: "World probe relighting", backfaceCulling: false, depthPixelFormat: .none)
        descriptor.colorAttachments = [.init(format: .rgba_16f)]
        let result = device.createRenderPipeline(from: descriptor)
        pipeline = result; nearest = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped))
        return result
    }
}
