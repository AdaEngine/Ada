import AdaECS
import AdaRender
import Math
import Synchronization

/// Per-camera performance/debug controls. Camera culling never controls the shadow caster list.
public struct MeshVisibilitySettings3D: Codable, Sendable {
    public var frustumCulling: Bool
    public var lod: Bool
    public var distanceCulling: Bool

    public init(frustumCulling: Bool = true, lod: Bool = true, distanceCulling: Bool = true) {
        self.frustumCulling = frustumCulling
        self.lod = lod
        self.distanceCulling = distanceCulling
    }
}

/// One extracted mesh entity, before camera/cascade visibility and static LOD selection.
public struct Mesh3DRenderSource: Sendable {
    public var drawPass: any DrawPass
    public var entity: Entity.ID
    public var mesh: Mesh
    public var materials: [Material]
    public var transform: Transform3D
    public var previousTransform: Transform3D
    public var bounds: AABB?
    public var alternatives: [Mesh]
    public var thresholds: [Float]
    public var hysteresis: Float
    public var maximumDistance: Float?
    public var fadeDistance: Float
    public var forceVisible: Bool
    public var castShadows: Bool
    public var receiveShadows: Bool
    public var skinningBuffer: (any UniformBuffer)?

    public init(
        entity: Entity.ID,
        drawPass: any DrawPass,
        mesh: Mesh,
        materials: [Material],
        transform: Transform3D,
        bounds: AABB?,
        alternatives: [Mesh] = [],
        thresholds: [Float] = [],
        hysteresis: Float = 0.15,
        maximumDistance: Float? = nil,
        fadeDistance: Float = 4,
        forceVisible: Bool = false,
        castShadows: Bool = true,
        receiveShadows: Bool = true,
        skinningBuffer: (any UniformBuffer)? = nil,
        previousTransform: Transform3D? = nil
    ) {
        self.previousTransform = previousTransform ?? transform
        self.drawPass = drawPass
        self.entity = entity; self.mesh = mesh; self.materials = materials; self.transform = transform; self.bounds = bounds
        self.alternatives = alternatives; self.thresholds = thresholds; self.hysteresis = hysteresis
        self.maximumDistance = maximumDistance; self.fadeDistance = fadeDistance; self.forceVisible = forceVisible
        self.castShadows = castShadows; self.receiveShadows = receiveShadows; self.skinningBuffer = skinningBuffer
    }
}

public struct ExtractedMesh3DSources: Resource {
    public var meshes: [Mesh3DRenderSource] = []
    public init() {}
}

public struct Visibility3DCount: Codable, Sendable {
    public var candidates = 0
    public var visibleMeshes = 0
    public var frustumRejected = 0
    public var distanceRejected = 0
    public var drawCalls = 0
    public var triangles = 0
    public var lod0Triangles = 0
    public var lodInstances: [Int] = [0, 0, 0]
    public init() {}
}

/// Local debug counters, independent of GPU timing collection.
public final class Render3DVisibilityStatistics: Resource, Sendable {
    private let state = Mutex<[String: Visibility3DCount]>([:])
    public init() {}
    public func record(_ count: Visibility3DCount, view: Entity.ID, pass: Int) {
        state.withLock { $0["\(view):\(pass < 0 ? "camera" : "shadow\(pass)")"] = count }
    }

    public var snapshots: [String: Visibility3DCount] { state.withLock { $0 } }
}

/// Metal/D3D clip convention: -W<=X,Y<=W, 0<=Z<=W. Conservative world-AABB rejection.
public enum MeshVisibility3DMath {
    public static func intersects(_ bounds: AABB, viewProjection: Transform3D) -> Bool {
        let row0 = viewProjection.row(at: 0), row1 = viewProjection.row(at: 1)
        let row2 = viewProjection.row(at: 2), row3 = viewProjection.row(at: 3)
        // Keeping uncertain bounds is safer than dropping geometry.
        if !bounds.center.x.isFinite || !bounds.center.y.isFinite || !bounds.center.z.isFinite {
            return true
        }
        for plane in [row3 + row0, row3 - row0, row3 + row1, row3 - row1, row2, row3 - row2] {
            let radius = abs(plane.x) * bounds.halfExtents.x + abs(plane.y) * bounds.halfExtents.y + abs(plane.z) * bounds.halfExtents.z
            if plane.xyz.dot(bounds.center) + plane.w + radius < -0.0001 {
                return false
            }
        }
        return true
    }

    public static func transformed(_ bounds: AABB, by matrix: Transform3D) -> AABB {
        let center = (matrix * Vector4(bounds.center, 1)).xyz
        let e = bounds.halfExtents
        let extents = Vector3(
            abs(matrix.x.x) * e.x + abs(matrix.y.x) * e.y + abs(matrix.z.x) * e.z,
            abs(matrix.x.y) * e.x + abs(matrix.y.y) * e.y + abs(matrix.z.y) * e.z,
            abs(matrix.x.z) * e.x + abs(matrix.y.z) * e.y + abs(matrix.z.z) * e.z
        )
        return AABB(center: center, halfExtents: extents)
    }

    public static func projectedDiameter(_ bounds: AABB, view: Transform3D, projection: Transform3D) -> Float {
        let radius = bounds.halfExtents.length
        let position = (view * Vector4(bounds.center, 1)).xyz
        let scale = abs(projection.y.y)
        if abs(projection.z.w) < 0.5 {
            return radius * scale
        }
        let depth = max(abs(position.z) - radius, 0.01)
        return radius * scale / depth
    }

    public static func selectLOD(size: Float, thresholds: [Float], levels: Int, previous: Int?, hysteresis: Float) -> Int {
        guard levels > 1, thresholds.count >= levels - 1,
              thresholds.prefix(levels - 1).allSatisfy({ $0.isFinite && $0 > 0 })
        else {
            return 0
        }
        for index in 1 ..< (levels - 1) where thresholds[index] >= thresholds[index - 1] {
            return 0
        }
        var level = min(max(previous ?? 0, 0), levels - 1)
        let margin = finiteRenderValue(hysteresis, fallback: 0.15, range: 0 ... 0.4)
        while level < levels - 1 && size < thresholds[level] * (1 - (previous == nil ? 0 : margin)) { level += 1 }
        while level > 0 && size > thresholds[level - 1] * (1 + (previous == nil ? 0 : margin)) { level -= 1 }
        return level
    }
}
