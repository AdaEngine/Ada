import AdaAssets
import AdaECS
import Math

/// An authored reference to a terrain manifest, retaining legacy patches as an independent compatible component.
@Component
public struct Terrain3DSource: Codable, Equatable, Sendable {
    public var source: String
    public var color: Vector4
    public var generatesCollision: Bool
    public var maximumResidentHeightBytes: Int
    public var maximumResidentRegions: Int
    public var maximumMeshBytes: Int
    /// Maximum render-only level (0...6). Collision and height queries always use full detail.
    public var maximumLOD: Int
    /// Terrain-local X/Z distance to the first LOD boundary; subsequent boundaries double.
    public var lodDistance: Float
    /// Optional terrain-local camera residency radius. Nil loads the complete declared set within limits.
    public var streamingRadius: Float?
    /// Terrain-local margin around swept physical bounds; extends residency beyond camera coverage.
    public var physicsPadding: Float
    /// Maximum changed tiles whose GPU meshes and collision resources are prepared per update.
    public var maximumTileUpdatesPerFrame: Int
    /// Decorative placements remain noncolliding; flagged static props use these independent bounds.
    public var instanceCollision: TerrainInstanceCollisionSettings
    /// Nil avoids query-index memory and construction when runtime/editor picking is unused.
    public var queries: TerrainSurfaceQuerySettings?
    /// Increment to retry a failed source without changing its path.
    public var reloadGeneration: UInt64

    public init(
        source: String = "",
        color: Vector4 = [0.28, 0.43, 0.18, 1],
        generatesCollision: Bool = true,
        maximumResidentHeightBytes: Int = 64 * 1_024 * 1_024,
        maximumResidentRegions: Int = 128,
        maximumMeshBytes: Int = 128 * 1_024 * 1_024,
        reloadGeneration: UInt64 = 0,
        maximumLOD: Int = 6,
        lodDistance: Float = 128,
        streamingRadius: Float? = 384,
        physicsPadding: Float = 64,
        maximumTileUpdatesPerFrame: Int = 4,
        instanceCollision: TerrainInstanceCollisionSettings = .init(),
        queries: TerrainSurfaceQuerySettings? = nil
    ) {
        self.source = source
        self.color = color
        self.generatesCollision = generatesCollision
        self.maximumResidentHeightBytes = maximumResidentHeightBytes
        self.maximumResidentRegions = maximumResidentRegions
        self.maximumMeshBytes = maximumMeshBytes
        self.maximumLOD = maximumLOD
        self.lodDistance = lodDistance
        self.streamingRadius = streamingRadius
        self.physicsPadding = physicsPadding
        self.maximumTileUpdatesPerFrame = maximumTileUpdatesPerFrame
        self.instanceCollision = instanceCollision
        self.queries = queries
        self.reloadGeneration = reloadGeneration
    }
}

/// Transient load/build diagnostics on the authored terrain entity.
public struct Terrain3DSourceStatus: Component, Sendable {
    public let isReady: Bool
    public let tileCount: Int
    public let warnings: [String]
    public let error: String?
    public let preparedTileCount: Int
    public let pendingTileCount: Int
    public let isPreparing: Bool
    public let instanceColliderCount: Int

    public init(
        isReady: Bool,
        tileCount: Int,
        error: String? = nil,
        preparedTileCount: Int = 0,
        pendingTileCount: Int = 0,
        isPreparing: Bool = false,
        warnings: [String] = [],
        instanceColliderCount: Int = 0
    ) {
        self.isReady = isReady
        self.tileCount = tileCount
        self.warnings = warnings
        self.error = error
        self.preparedTileCount = preparedTileCount
        self.pendingTileCount = pendingTileCount
        self.isPreparing = isPreparing
        self.instanceColliderCount = instanceColliderCount
    }
}

/// Runtime height data for queries and local edits. The source system watches its revisions.
public struct Terrain3DSourceSurface: Component, Sendable {
    public let storage: TerrainHeightStorage
    public let queries: TerrainSurfaceQueries?
    /// Immutable loaded/saved resource generation, for optimistic editor authoring checkpoints.
    public let manifest: TerrainManifestAsset?

    init(storage: TerrainHeightStorage, queries: TerrainSurfaceQueries? = nil, manifest: TerrainManifestAsset? = nil) {
        self.storage = storage; self.queries = queries; self.manifest = manifest
    }
}
