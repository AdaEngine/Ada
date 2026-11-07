@_spi(Internal) import AdaAssets
@_spi(Internal) import AdaRender
import Foundation
import Math
import Synchronization

/// A region address in the terrain's 256-cell X/Z grid.
public struct TerrainRegionCoordinate: Codable, Hashable, Sendable, Comparable {
    public var x: Int
    public var z: Int

    public init(x: Int, z: Int) { self.x = x; self.z = z }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.z == rhs.z ? lhs.x < rhs.x : lhs.z < rhs.z
    }
}

/// An integer height sample address, measured from the terrain's local origin.
public struct TerrainGridPoint: Codable, Hashable, Sendable {
    public var x: Int
    public var z: Int

    public init(x: Int, z: Int) { self.x = x; self.z = z }
}

/// An immutable tile snapshot whose geometry includes normals derived from neighboring samples.
public struct TerrainHeightTileSnapshot: Sendable {
    public let coordinate: TerrainTileCoordinate
    public let cellCountX: Int
    public let cellCountZ: Int
    public let heights: [Float]
    public let normals: [Vector3]
    public let revision: UInt64
    let descriptor: MeshDescriptor

    public func meshDescriptor() -> MeshDescriptor { descriptor }
}

/// Immutable input generation for one placement cell. Staged copies preserve identity until rows change.
struct TerrainInstanceCellRows: Sendable {
    let id: UUID
    var records: [TerrainRegionInstance]

    init(id: UUID = UUID(), records: [TerrainRegionInstance] = []) { self.id = id; self.records = records }
}

/// Sparse authored heights and placements with canonical samples and independent allocation budgets.
public final class TerrainHeightStorage: Sendable {
    public static let cellsPerTile = Terrain3D.defaultTileCellCount
    public static let cellsPerRegion = 256

    public enum StorageError: Error {
        case invalidConfiguration
        case invalidCoordinate
        case missingSurface
        case memoryBudgetExceeded
        case staleRevision
    }

    /// Distance between adjacent samples in terrain-local units.
    public let spacing: Float
    /// Terrain-local X/Z position of sample (0, 0).
    public let origin: Vector2
    /// Maximum bytes in canonical Float height pages; snapshots and GPU data have separate budgets.
    public var memoryBudgetBytes: Int { state.withLock { $0.budgetBytes } }

    private struct Tile: Sendable {
        var width: Int
        var depth: Int
        var revision: UInt64
    }

    private struct Page: Sendable {
        var generation = UUID()
        var samples = Array(repeating: Float(0), count: cellsPerTile * cellsPerTile)
        var nonzeroCount = 0
    }

    private struct State: Sendable {
        var identity = UUID()
        var tiles: [TerrainTileCoordinate: Tile] = [:]
        var normalTiles: [TerrainTileCoordinate: Tile] = [:]
        var pages: [TerrainTileCoordinate: Page] = [:]
        var instanceCells: [TerrainTileCoordinate: TerrainInstanceCellRows] = [:]
        var surfaceData = TerrainSurfaceStorageRows()
        var instanceCount = 0
        var exportedInstanceRecordCount = 0
        var instanceLocations: [UInt64: TerrainTileCoordinate] = [:]
        var instanceBudgetBytes = 0
        var dirty: [TerrainTileCoordinate] = []
        var dirtyHead = 0
        var dirtyOverflowGeneration: UInt64 = 0
        var dirtySet: Set<TerrainTileCoordinate> = []
        var revision: UInt64 = 0
        var tracksDirtyTiles = true
        var budgetBytes = 0
    }

    static let gridLimit = 1_048_576
    private static let maximumTiles = 65_536
    private static let tilesPerRegion = cellsPerRegion / cellsPerTile
    private static let instanceBytes = MemoryLayout<TerrainRegionInstance>.stride
    private static let pageBytes = cellsPerTile * cellsPerTile * MemoryLayout<Float>.stride
    private let state = Mutex(State())

    public init(
        spacing: Float = 1,
        origin: Vector2 = .zero,
        memoryBudgetBytes: Int = 64 * 1_024 * 1_024,
        instanceMemoryBudgetBytes: Int = 16 * 1_024 * 1_024,
        surfaceMemoryBudgetBytes: Int = 32 * 1_024 * 1_024
    ) throws {
        let extent = Float(Self.gridLimit) * spacing
        guard spacing.isFinite, spacing > 0, origin.x.isFinite, origin.y.isFinite, memoryBudgetBytes >= 0, instanceMemoryBudgetBytes >= 0, surfaceMemoryBudgetBytes >= 0,
            extent.isFinite, (origin.x - extent).isFinite, (origin.x + extent).isFinite,
            (origin.y - extent).isFinite, (origin.y + extent).isFinite
        else {
            throw StorageError.invalidConfiguration
        }
        self.spacing = spacing
        self.origin = origin
        state.withLock {
            $0.budgetBytes = memoryBudgetBytes
            $0.instanceBudgetBytes = instanceMemoryBudgetBytes
            $0.surfaceData.budgetBytes = surfaceMemoryBudgetBytes
        }
    }

    public convenience init(importing terrain: Terrain3D, memoryBudgetBytes: Int = 64 * 1_024 * 1_024) throws {
        try terrain.validate()
        try self.init(spacing: terrain.size / Float(terrain.resolution - 1), origin: Vector2(-terrain.size / 2), memoryBudgetBytes: memoryBudgetBytes)
        try state.withLock { value in
            value.revision &+= 1
            for z in stride(from: 0, to: terrain.resolution - 1, by: Self.cellsPerTile) {
                for x in stride(from: 0, to: terrain.resolution - 1, by: Self.cellsPerTile) {
                    let coordinate = TerrainTileCoordinate(x: x / Self.cellsPerTile, z: z / Self.cellsPerTile)
                    value.tiles[coordinate] = Tile(
                        width: min(Self.cellsPerTile, terrain.resolution - 1 - x),
                        depth: min(Self.cellsPerTile, terrain.resolution - 1 - z),
                        revision: value.revision
                    )
                    Self.mark(coordinate, state: &value)
                }
            }
            for z in 0..<terrain.resolution {
                for x in 0..<terrain.resolution {
                    _ = try Self.write(terrain.heights[z * terrain.resolution + x], at: .init(x: x, z: z), budget: memoryBudgetBytes, state: &value)
                }
            }
        }
    }

    /// Restores an immutable set of independently decoded region resources.
    public convenience init(
        regions: [TerrainRegionAsset],
        spacing: Float = 1,
        origin: Vector2 = .zero,
        memoryBudgetBytes: Int = 64 * 1_024 * 1_024,
        instanceMemoryBudgetBytes: Int = 16 * 1_024 * 1_024,
        surfaceMemoryBudgetBytes: Int = 32 * 1_024 * 1_024
    ) throws {
        try self.init(
            spacing: spacing,
            origin: origin,
            memoryBudgetBytes: memoryBudgetBytes,
            instanceMemoryBudgetBytes: instanceMemoryBudgetBytes,
            surfaceMemoryBudgetBytes: surfaceMemoryBudgetBytes
        )
        guard regions.count <= Self.maximumTiles else { throw StorageError.memoryBudgetExceeded }
        try state.withLock { value in
            var addresses: Set<TerrainRegionCoordinate> = []
            for region in regions {
                try region.validate()
                let address = TerrainRegionCoordinate(x: Int(region.x), z: Int(region.z))
                guard addresses.insert(address).inserted else { throw StorageError.invalidConfiguration }
                guard value.tiles.count <= Self.maximumTiles - region.tiles.count,
                    region.instances.count <= value.instanceBudgetBytes / Self.instanceBytes - value.instanceCount
                else {
                    throw StorageError.memoryBudgetExceeded
                }
                for record in region.instances {
                    let cell = TerrainTileCoordinate(
                        x: address.x * Self.tilesPerRegion + Int(record.localPosition.x) / Self.cellsPerTile,
                        z: address.z * Self.tilesPerRegion + Int(record.localPosition.z) / Self.cellsPerTile
                    )
                    guard value.instanceLocations.updateValue(cell, forKey: record.id) == nil else { throw StorageError.invalidConfiguration }
                    if value.instanceCells[cell] == nil, value.instanceCells.count == Self.maximumTiles { throw StorageError.memoryBudgetExceeded }
                    value.instanceCells[cell, default: .init()].records.append(record)
                }
                value.instanceCount += region.instances.count
                try value.surfaceData.insert(region)
                for tile in region.tiles {
                    let coordinate = TerrainTileCoordinate(
                        x: address.x * Self.tilesPerRegion + Int(tile.x),
                        z: address.z * Self.tilesPerRegion + Int(tile.z)
                    )
                    value.tiles[coordinate] = Tile(width: Int(tile.cellCountX), depth: Int(tile.cellCountZ), revision: 1)
                }
                for page in region.pages {
                    let nonzeroCount = page.samples.reduce(into: 0) { if $1 != 0 { $0 += 1 } }
                    guard nonzeroCount > 0 else { continue }
                    guard value.pages.count < memoryBudgetBytes / Self.pageBytes else { throw StorageError.memoryBudgetExceeded }
                    let coordinate = TerrainTileCoordinate(
                        x: address.x * Self.tilesPerRegion + Int(page.x),
                        z: address.z * Self.tilesPerRegion + Int(page.z)
                    )
                    value.pages[coordinate] = Page(samples: page.samples, nonzeroCount: nonzeroCount)
                }
            }
            if !value.tiles.isEmpty || !value.pages.isEmpty || value.instanceCount > 0 || !value.surfaceData.cells.isEmpty { value.revision = 1 }
            for coordinate in value.tiles.keys.sorted() { Self.mark(coordinate, state: &value) }
        }
    }

    /// Addresses with physical tiles, canonical samples or placements, including boundary-only resources.
    public var resourceCoordinates: [TerrainRegionCoordinate] {
        state.withLock { value in
            var coordinates: Set<TerrainRegionCoordinate> = []
            for tile in value.tiles.keys { coordinates.insert(Self.region(containing: tile)) }
            for page in value.pages.keys { coordinates.insert(Self.region(containing: page)) }
            for cell in value.instanceCells.keys { coordinates.insert(Self.region(containing: cell)) }
            for cell in value.surfaceData.cells.keys { coordinates.insert(Self.region(containing: cell)) }
            return coordinates.sorted()
        }
    }

    /// Copies one portable region payload without loading neighboring resources or creating render objects.
    public func regionAsset(at coordinate: TerrainRegionCoordinate) throws -> TerrainRegionAsset? {
        try Self.validateResource(coordinate)
        return state.withLock { value in
            var tiles: [TerrainRegionTile] = []
            var pages: [TerrainRegionHeightPage] = []
            var records: [TerrainRegionInstance] = []
            for z in 0..<Self.tilesPerRegion {
                for x in 0..<Self.tilesPerRegion {
                    let address = TerrainTileCoordinate(x: coordinate.x * Self.tilesPerRegion + x, z: coordinate.z * Self.tilesPerRegion + z)
                    if let tile = value.tiles[address] {
                        tiles.append(.init(x: UInt8(x), z: UInt8(z), cellCountX: UInt8(tile.width), cellCountZ: UInt8(tile.depth)))
                    }
                    if let page = value.pages[address] { pages.append(.init(x: UInt8(x), z: UInt8(z), samples: page.samples)) }
                    if let instances = value.instanceCells[address] { records.append(contentsOf: instances.records) }
                }
            }
            let channels = value.surfaceData.records(in: coordinate)
            guard !tiles.isEmpty || !pages.isEmpty || !records.isEmpty || !channels.surface.isEmpty || !channels.masks.isEmpty else {
                return nil
            }
            let exported = value.exportedInstanceRecordCount.addingReportingOverflow(records.count)
            value.exportedInstanceRecordCount = exported.overflow ? Int.max : exported.partialValue
            return TerrainRegionAsset(
                x: Int32(coordinate.x),
                z: Int32(coordinate.z),
                tiles: tiles,
                pages: pages,
                instances: records,
                surface: channels.surface,
                ruleMasks: channels.masks
            )
        }
    }

    public var regionCoordinates: [TerrainRegionCoordinate] {
        state.withLock { value in
            Set(value.tiles.keys.map { Self.region(containing: $0) })
                .union(value.instanceCells.keys.map { Self.region(containing: $0) })
                .union(value.surfaceData.cells.keys.map { Self.region(containing: $0) }).sorted()
        }
    }
    /// Immutable COW cell rows, including resident data retained only for halos/dirty pins.
    func instanceCellSnapshot() -> [TerrainTileCoordinate: TerrainInstanceCellRows] { state.withLock { $0.instanceCells } }

    func containsInstance(id: UInt64) -> Bool { state.withLock { $0.instanceLocations[id] != nil } }

    /// Counts actual placement rows copied into portable payloads; consuming diagnostics does not edit terrain.
    func takeExportedInstanceRecordCount() -> Int {
        state.withLock { value in
            let count = value.exportedInstanceRecordCount
            value.exportedInstanceRecordCount = 0
            return count
        }
    }

    public var tileCoordinates: [TerrainTileCoordinate] { state.withLock { $0.tiles.keys.sorted() } }
    /// Generation of content, residency or an accepted budget change. A tile's revision reflects affected geometry/normals.
    public var revision: UInt64 { state.withLock { $0.revision } }

    var volumeBaseIdentity: UUID { state.withLock { $0.identity } }

    func volumeBaseCell(at coordinate: TerrainTileCoordinate) -> TerrainVolumeBaseCell {
        state.withLock { value in
            let coverage = value.tiles[coordinate] ?? value.normalTiles[coordinate]
            return .init(
                coordinate: coordinate,
                width: coverage.map { Int32($0.width) } ?? 0,
                depth: coverage.map { Int32($0.depth) } ?? 0,
                pageGeneration: value.pages[coordinate]?.generation
            )
        }
    }

    /// Bytes held by canonical height pages; excludes mesh snapshots and GPU allocations.
    public var residentHeightBytes: Int { state.withLock { $0.pages.count * Self.pageBytes } }
    /// Decoded placement-record bytes; cell indices, temporary snapshots and GPU rows are separate costs.
    public var residentInstanceBytes: Int { state.withLock { $0.instanceCount * Self.instanceBytes } }
    public var instanceMemoryBudgetBytes: Int { state.withLock { $0.instanceBudgetBytes } }
    /// Conservative decoded/hash-table/COW allowance for sparse authored surface channels.
    public var residentSurfaceBytes: Int { state.withLock { $0.surfaceData.chargedBytes } }
    public var surfaceMemoryBudgetBytes: Int { state.withLock { $0.surfaceData.budgetBytes } }

    /// Reads artist-authored channels independently of automatic material evaluation and draw coverage.
    public func paint(atSample point: TerrainGridPoint) -> TerrainSurfacePaint? {
        guard Self.isValid(point) else {
            return nil
        }
        return state.withLock { $0.surfaceData.sample(at: point)?.paint }
    }

    /// Missing or erased sparse rule masks read as zero.
    public func ruleMask(atSample point: TerrainGridPoint, id: UInt16) -> Float {
        guard Self.isValid(point) else {
            return 0
        }
        return state.withLock { $0.surfaceData.mask(at: point, id: id) }
    }

    func surfaceSnapshot() -> TerrainSurfaceStorageRows { state.withLock { $0.surfaceData } }
    /// Changes when the 65,536-entry dirty queue overflows. Consumers must discard their derived
    /// tile set and resynchronize from tileCoordinates before continuing with queued deltas.
    public var dirtyOverflowGeneration: UInt64 { state.withLock { $0.dirtyOverflowGeneration } }
    public var hasDirtyTiles: Bool { state.withLock { $0.dirtyHead < $0.dirty.count } }

    /// Adds a flat region, preserving canonical samples already shared with neighboring regions.
    @discardableResult
    public func allocateRegion(at coordinate: TerrainRegionCoordinate) throws -> Bool {
        try Self.validate(coordinate)
        return try state.withLock { value in
            var changed: [TerrainTileCoordinate] = []
            for z in 0..<Self.tilesPerRegion {
                for x in 0..<Self.tilesPerRegion {
                    let tile = TerrainTileCoordinate(x: coordinate.x * Self.tilesPerRegion + x, z: coordinate.z * Self.tilesPerRegion + z)
                    if value.tiles[tile]?.width != Self.cellsPerTile || value.tiles[tile]?.depth != Self.cellsPerTile { changed.append(tile) }
                }
            }
            guard !changed.isEmpty else {
                return false
            }
            let additions = changed.filter { value.tiles[$0] == nil }.count
            guard value.tiles.count + additions <= Self.maximumTiles else { throw StorageError.memoryBudgetExceeded }
            let authoredAdditions = changed.filter { value.tiles[$0] == nil && value.normalTiles[$0] == nil }.count
            if authoredAdditions > 0 { try Self.validateNativeRegionBudget(coordinate, tileDelta: authoredAdditions, state: value) }
            value.revision &+= 1
            for tile in changed { value.tiles[tile] = Tile(width: Self.cellsPerTile, depth: Self.cellsPerTile, revision: value.revision) }
            for tile in changed { Self.markNeighbors(of: tile, state: &value) }
            return true
        }
    }

    /// Removes the region's surface and placements. Record-only removal retains canonical height data.
    @discardableResult
    public func removeRegion(at coordinate: TerrainRegionCoordinate) throws -> Bool {
        try Self.validateResource(coordinate)
        return state.withLock { value in
            let removed = value.tiles.keys.filter {
                Self.floorDiv($0.x, by: Self.tilesPerRegion) == coordinate.x && Self.floorDiv($0.z, by: Self.tilesPerRegion) == coordinate.z
            }
            let instanceCells = value.instanceCells.keys.filter { Self.region(containing: $0) == coordinate }
            if removed.isEmpty && instanceCells.isEmpty {
                let oldSamples = value.surfaceData.sampleCount, oldMasks = value.surfaceData.maskCount
                let coverage = value
                value.surfaceData.prune(near: coordinate) { Self.containsSample($0, state: coverage, includeNormalCoverage: true) }
                guard oldSamples != value.surfaceData.sampleCount || oldMasks != value.surfaceData.maskCount else {
                    return false
                }
                value.revision &+= 1
                return true
            }
            value.revision &+= 1
            for cell in instanceCells {
                if let rows = value.instanceCells.removeValue(forKey: cell) {
                    value.instanceCount -= rows.records.count
                    for record in rows.records { value.instanceLocations.removeValue(forKey: record.id) }
                }
            }
            if !removed.isEmpty {
                for tile in removed { value.tiles.removeValue(forKey: tile) }
                value.normalTiles = value.normalTiles.filter { Self.region(containing: $0.key) != coordinate }
                for tile in removed {
                    Self.mark(tile, state: &value, removed: true)
                    Self.markNeighbors(of: tile, state: &value)
                }
                // Only these pages can contain samples orphaned by this region removal.
                for z in 0...Self.tilesPerRegion {
                    for x in 0...Self.tilesPerRegion {
                        Self.prune(.init(x: coordinate.x * Self.tilesPerRegion + x, z: coordinate.z * Self.tilesPerRegion + z), state: &value)
                    }
                }
            }
            let coverage = value
            value.surfaceData.prune(near: coordinate) { Self.containsSample($0, state: coverage, includeNormalCoverage: true) }
            return true
        }
    }

    /// Changes a canonical sample; unchanged writes neither allocate pages nor invalidate tiles.
    @discardableResult
    public func setHeight(_ height: Float, at point: TerrainGridPoint) throws -> Bool {
        guard height.isFinite else { throw StorageError.invalidConfiguration }
        guard Self.isValid(point) else { throw StorageError.invalidCoordinate }
        return try state.withLock { value in
            guard Self.containsSample(point, state: value) else { throw StorageError.missingSurface }
            let page = Self.locate(point).page
            if height != 0, value.pages[page] == nil {
                try Self.validateNativeRegionBudget(Self.region(containing: page), pageDelta: 1, state: value)
            }
            guard try Self.write(height, at: point, budget: value.budgetBytes, state: &value) else {
                return false
            }
            value.revision &+= 1
            Self.markSample(point, state: &value)
            return true
        }
    }

    /// Applies to a private staged snapshot; height and automatic attachment changes share one revision.
    func applyAnchorChanges(_ changes: [TerrainInstanceCellChange], expectedRevision: UInt64) throws {
        _ = try applyInstanceChanges(changes, expectedRevision: expectedRevision, advanceRevision: false)
    }

    func applyInstanceChanges(_ changes: [TerrainInstanceCellChange], expectedRevision: UInt64, advanceRevision: Bool) throws -> [TerrainInstanceCellChange] {
        try state.withLock { value in
            guard value.revision == expectedRevision else { throw TerrainHeightEditError.staleRevision }
            let prepared = try TerrainInstanceEditKernel(
                changes,
                cells: value.instanceCells,
                locations: value.instanceLocations,
                count: value.instanceCount,
                maximumCount: value.instanceBudgetBytes / Self.instanceBytes
            )
            value.instanceCells = prepared.cells
            value.instanceLocations = prepared.locations
            value.instanceCount = prepared.count
            if advanceRevision && !prepared.changes.isEmpty { value.revision &+= 1 }
            return prepared.changes
        }
    }

    func applySurfaceUpdates(
        _ surface: [TerrainSurfaceUpdate],
        masks: [TerrainRuleMaskUpdate],
        layers: Set<UInt16>?,
        expectedRevision: UInt64,
        advanceRevision: Bool
    ) throws -> (surface: [TerrainSurfaceChange], masks: [TerrainRuleMaskChange]) {
        try state.withLock { value in
            guard value.revision == expectedRevision else { throw TerrainHeightEditError.staleRevision }
            let prepared = try TerrainSurfaceEditKernel(
                surface: surface,
                masks: masks,
                original: value.surfaceData,
                layers: layers,
                contains: { Self.containsSample($0, state: value, includeNormalCoverage: true) }
            )
            value.surfaceData = prepared.storage
            if advanceRevision && !prepared.points.isEmpty { value.revision &+= 1 }
            for point in prepared.points { Self.markSample(point, state: &value) }
            return (prepared.surface, prepared.masks)
        }
    }

    /// All authored layouts count, including hidden normal coverage and canonical boundary-only resources.
    /// This metadata-only guard applies to height, placement and paint gestures before publication.
    func validateNativeRegionBudgets() throws {
        try state.withLock { value in
            var regions: Set<TerrainRegionCoordinate> = []
            for cell in value.tiles.keys { regions.insert(Self.region(containing: cell)) }
            for cell in value.normalTiles.keys { regions.insert(Self.region(containing: cell)) }
            for cell in value.pages.keys { regions.insert(Self.region(containing: cell)) }
            for cell in value.instanceCells.keys { regions.insert(Self.region(containing: cell)) }
            for cell in value.surfaceData.cells.keys { regions.insert(Self.region(containing: cell)) }
            for region in regions {
                try Task.checkCancellation()
                try Self.validateNativeRegionBudget(region, state: value)
            }
        }
    }

    private static func validateNativeRegionBudget(_ region: TerrainRegionCoordinate, tileDelta: Int = 0, pageDelta: Int = 0, state: State) throws {
        var tiles = tileDelta, pages = pageDelta, instances = 0
        for z in 0..<tilesPerRegion {
            for x in 0..<tilesPerRegion {
                let cell = TerrainTileCoordinate(x: region.x * tilesPerRegion + x, z: region.z * tilesPerRegion + z)
                if state.tiles[cell] != nil || state.normalTiles[cell] != nil { tiles += 1 }
                if state.pages[cell] != nil { pages += 1 }
                instances += state.instanceCells[cell]?.records.count ?? 0
            }
        }
        let fields = state.surfaceData.counts(in: region)
        try TerrainRegionAsset.validateRecordBudget(
            tileCount: tiles,
            pageCount: pages,
            instanceCount: instances,
            surfaceCount: fields.surface,
            ruleMaskCount: fields.masks
        )
    }

    /// Returns a canonical sample, or nil when no allocated surface includes it.
    public func height(atSample point: TerrainGridPoint) -> Float? {
        state.withLock { value in Self.containsSample(point, state: value) ? Self.read(point, state: value) : nil }
    }

    /// Samples the authored triangles in terrain-local coordinates, including outer boundary edges.
    public func height(at point: Vector2) -> Float? { sampledHeight(at: point, includeNormalCoverage: false) }

    /// Attachment queries use authored coverage retained for halos, without making hidden tiles visible.
    func heightForAnchor(at point: Vector2) -> Float? { sampledHeight(at: point, includeNormalCoverage: true) }

    private func sampledHeight(at point: Vector2, includeNormalCoverage: Bool) -> Float? {
        let grid = (point - origin) / spacing
        guard grid.x.isFinite, grid.y.isFinite, abs(grid.x) <= Float(Self.gridLimit), abs(grid.y) <= Float(Self.gridLimit) else {
            return nil
        }
        let baseX = Int(grid.x.rounded(.down)), baseZ = Int(grid.y.rounded(.down))
        return state.withLock { value in
            let xs = grid.x == Float(baseX) ? [baseX, baseX - 1] : [baseX]
            let zs = grid.y == Float(baseZ) ? [baseZ, baseZ - 1] : [baseZ]
            for z in zs {
                for x in xs where Self.containsCell(x: x, z: z, state: value, includeNormalCoverage: includeNormalCoverage) {
                    let fx = Double(grid.x) - Double(x), fz = Double(grid.y) - Double(z)
                    let a = Double(Self.read(.init(x: x, z: z), state: value))
                    let b = Double(Self.read(.init(x: x + 1, z: z), state: value))
                    let c = Double(Self.read(.init(x: x, z: z + 1), state: value))
                    let d = Double(Self.read(.init(x: x + 1, z: z + 1), state: value))
                    let interpolated: Double
                    if fx + fz <= 1 {
                        interpolated = a + (b - a) * fx + (c - a) * fz
                    } else {
                        interpolated = d + (c - d) * (1 - fx) + (b - d) * (1 - fz)
                    }
                    return Float(interpolated)
                }
            }
            return nil
        }
    }

    /// Returns the tile's current generation, or nil after removal.
    public func tileRevision(at coordinate: TerrainTileCoordinate) -> UInt64? { state.withLock { $0.tiles[coordinate]?.revision } }

    /// Metadata-only lookup for LOD selection; does not allocate geometry snapshots.
    func tileCellCounts(at coordinate: TerrainTileCoordinate) -> (x: Int, z: Int)? {
        state.withLock { value in value.tiles[coordinate].map { ($0.width, $0.depth) } }
    }

    /// Drains a single-consumer FIFO of changed or removed tiles. A removed tile has no snapshot.
    /// Independent consumers can use ``revision`` and ``tileRevision(at:)`` without draining this queue.
    public func takeDirtyTiles(limit: Int) -> [TerrainTileCoordinate] {
        guard limit > 0 else {
            return []
        }
        return state.withLock { value in
            let end = value.dirtyHead + min(limit, value.dirty.count - value.dirtyHead)
            let result = Array(value.dirty[value.dirtyHead..<end])
            for coordinate in result { value.dirtySet.remove(coordinate) }
            value.dirtyHead = end
            if end == value.dirty.count {
                value.dirty.removeAll(keepingCapacity: true)
                value.dirtyHead = 0
            } else if end > 1_024, end > value.dirty.count / 2 {
                value.dirty.removeFirst(end)
                value.dirtyHead = 0
            }
            return result
        }
    }

    /// Copies one tile's geometry atomically. Returned arrays never change after later edits.
    public func snapshot(of coordinate: TerrainTileCoordinate) -> TerrainHeightTileSnapshot? {
        state.withLock { value in
            guard let tile = value.tiles[coordinate] else {
                return nil
            }
            return makeSnapshot(coordinate, tile: tile, state: value)
        }
    }
}

extension TerrainHeightStorage {
    private static func region(containing tile: TerrainTileCoordinate) -> TerrainRegionCoordinate {
        .init(x: floorDiv(tile.x, by: tilesPerRegion), z: floorDiv(tile.z, by: tilesPerRegion))
    }

    private static func floorDiv(_ value: Int, by divisor: Int) -> Int {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }

    private static func validateResource(_ coordinate: TerrainRegionCoordinate) throws {
        let limit = gridLimit / cellsPerRegion
        guard (-limit...limit).contains(coordinate.x), (-limit...limit).contains(coordinate.z) else {
            throw StorageError.invalidCoordinate
        }
    }

    private static func validate(_ coordinate: TerrainRegionCoordinate) throws {
        let limit = gridLimit / cellsPerRegion
        guard (-limit..<limit).contains(coordinate.x), (-limit..<limit).contains(coordinate.z) else { throw StorageError.invalidCoordinate }
    }

    private static func isValid(_ point: TerrainGridPoint) -> Bool {
        (-gridLimit...gridLimit).contains(point.x) && (-gridLimit...gridLimit).contains(point.z)
    }

    private static func locate(_ point: TerrainGridPoint) -> (page: TerrainTileCoordinate, index: Int) {
        let x = point.x % cellsPerTile, z = point.z % cellsPerTile
        let localX = x < 0 ? x + cellsPerTile : x, localZ = z < 0 ? z + cellsPerTile : z
        return (.init(x: floorDiv(point.x, by: cellsPerTile), z: floorDiv(point.z, by: cellsPerTile)), localZ * cellsPerTile + localX)
    }

    private static func read(_ point: TerrainGridPoint, state: State) -> Float {
        let address = locate(point)
        return state.pages[address.page]?.samples[address.index] ?? 0
    }

    private static func write(_ height: Float, at point: TerrainGridPoint, budget: Int, state: inout State) throws -> Bool {
        let address = locate(point)
        let old = state.pages[address.page]?.samples[address.index] ?? 0
        guard old != height else {
            return false
        }
        if state.pages[address.page] == nil {
            guard state.pages.count < budget / pageBytes else { throw StorageError.memoryBudgetExceeded }
            state.pages[address.page] = Page()
        }
        state.pages[address.page]?.samples[address.index] = height
        state.pages[address.page]?.generation = UUID()
        if old == 0 { state.pages[address.page]?.nonzeroCount += 1 }
        if height == 0 { state.pages[address.page]?.nonzeroCount -= 1 }
        if state.pages[address.page]?.nonzeroCount == 0 { state.pages.removeValue(forKey: address.page) }
        return true
    }

    private static func containsSample(_ point: TerrainGridPoint, state: State, includeNormalCoverage: Bool = false) -> Bool {
        guard isValid(point) else {
            return false
        }
        let owner = locate(point).page
        let xCount = point.x % cellsPerTile == 0 ? 2 : 1
        let zCount = point.z % cellsPerTile == 0 ? 2 : 1
        for dz in 0..<zCount {
            let z = owner.z - dz
            for dx in 0..<xCount {
                let x = owner.x - dx
                let coordinate = TerrainTileCoordinate(x: x, z: z)
                guard let tile = state.tiles[coordinate] ?? (includeNormalCoverage ? state.normalTiles[coordinate] : nil) else { continue }
                let localX = point.x - x * cellsPerTile, localZ = point.z - z * cellsPerTile
                if (0...tile.width).contains(localX), (0...tile.depth).contains(localZ) {
                    return true
                }
            }
        }
        return false
    }

    private static func containsCell(x: Int, z: Int, state: State, includeNormalCoverage: Bool = false) -> Bool {
        let owner = TerrainTileCoordinate(x: floorDiv(x, by: cellsPerTile), z: floorDiv(z, by: cellsPerTile))
        guard let tile = state.tiles[owner] ?? (includeNormalCoverage ? state.normalTiles[owner] : nil) else {
            return false
        }
        return x - owner.x * cellsPerTile < tile.width && z - owner.z * cellsPerTile < tile.depth
    }

    private static func mark(_ coordinate: TerrainTileCoordinate, state: inout State, removed: Bool = false) {
        guard removed || state.tiles[coordinate] != nil else {
            return
        }
        state.tiles[coordinate]?.revision = state.revision
        guard state.tracksDirtyTiles else {
            return
        }
        guard !state.dirtySet.contains(coordinate) else {
            return
        }
        if state.dirtySet.count == maximumTiles {
            state.dirty.removeAll(keepingCapacity: true)
            state.dirtySet.removeAll(keepingCapacity: true)
            state.dirtyHead = 0
            state.dirtyOverflowGeneration &+= 1
        }
        state.dirtySet.insert(coordinate)
        state.dirty.append(coordinate)
    }

    private static func markNeighbors(of coordinate: TerrainTileCoordinate, state: inout State) {
        for z in -1...1 {
            for x in -1...1 { mark(.init(x: coordinate.x + x, z: coordinate.z + z), state: &state) }
        }
    }

    private static func prune(_ coordinate: TerrainTileCoordinate, state: inout State) {
        guard let page = state.pages[coordinate] else {
            return
        }
        var samples = page.samples
        var count = page.nonzeroCount
        for index in samples.indices where samples[index] != 0 {
            let point = TerrainGridPoint(x: coordinate.x * cellsPerTile + index % cellsPerTile, z: coordinate.z * cellsPerTile + index / cellsPerTile)
            if !containsSample(point, state: state, includeNormalCoverage: true) { samples[index] = 0; count -= 1 }
        }
        guard count != page.nonzeroCount else {
            return
        }
        if count == 0 { state.pages.removeValue(forKey: coordinate) } else { state.pages[coordinate] = Page(samples: samples, nonzeroCount: count) }
    }

    private func normal(x: Int, z: Int, state: State) -> Vector3 {
        let left = Self.containsSample(.init(x: x - 1, z: z), state: state, includeNormalCoverage: true) ? x - 1 : x
        let right = Self.containsSample(.init(x: x + 1, z: z), state: state, includeNormalCoverage: true) ? x + 1 : x
        let back = Self.containsSample(.init(x: x, z: z - 1), state: state, includeNormalCoverage: true) ? z - 1 : z
        let front = Self.containsSample(.init(x: x, z: z + 1), state: state, includeNormalCoverage: true) ? z + 1 : z
        let dx = (Double(Self.read(.init(x: right, z: z), state: state)) - Double(Self.read(.init(x: left, z: z), state: state))) / (Double(right - left) * Double(spacing))
        let dz = (Double(Self.read(.init(x: x, z: front), state: state)) - Double(Self.read(.init(x: x, z: back), state: state))) / (Double(front - back) * Double(spacing))
        let length = (dx * dx + 1 + dz * dz).squareRoot()
        return Vector3(Float(-dx / length), Float(1 / length), Float(-dz / length))
    }

    private func makeSnapshot(_ coordinate: TerrainTileCoordinate, tile: Tile, state: State) -> TerrainHeightTileSnapshot {
        let width = tile.width + 1
        let count = width * (tile.depth + 1)
        var heights: [Float] = [], positions: [Vector3] = [], normals: [Vector3] = [], uvs: [Vector2] = []
        var indices: [UInt32] = []
        heights.reserveCapacity(count)
        positions.reserveCapacity(count)
        normals.reserveCapacity(count)
        uvs.reserveCapacity(count)
        indices.reserveCapacity(tile.width * tile.depth * 6)
        for z in 0...tile.depth {
            for x in 0...tile.width {
                let gx = coordinate.x * Self.cellsPerTile + x, gz = coordinate.z * Self.cellsPerTile + z
                let height = Self.read(.init(x: gx, z: gz), state: state)
                let position = Vector3(Float(gx) * spacing + origin.x, height, Float(gz) * spacing + origin.y)
                heights.append(height)
                positions.append(position)
                normals.append(normal(x: gx, z: gz, state: state))
                uvs.append(Vector2(position.x, position.z))
                if x < tile.width, z < tile.depth {
                    let a = UInt32(z * width + x), b = a + 1, c = a + UInt32(width), d = c + 1
                    indices.append(contentsOf: [a, c, b, b, c, d])
                }
            }
        }
        var descriptor = MeshDescriptor(name: "Terrain Tile \(coordinate.x),\(coordinate.z)")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.indicies = indices
        return TerrainHeightTileSnapshot(
            coordinate: coordinate,
            cellCountX: tile.width,
            cellCountZ: tile.depth,
            heights: heights,
            normals: normals,
            revision: tile.revision,
            descriptor: descriptor
        )
    }
}

extension TerrainHeightStorage {
    /// Builds an isolated candidate; visible tiles and normal-only halo topology have separate ownership.
    func residencySnapshot(
        regions: [TerrainRegionAsset],
        visible: Set<TerrainRegionCoordinate>,
        expectedRevision: UInt64,
        memoryBudgetBytes: Int? = nil
    ) throws -> TerrainHeightStorage {
        let previous = try state.withLock { value in
            guard value.revision == expectedRevision else { throw StorageError.staleRevision }
            return value
        }
        let candidate = try TerrainHeightStorage(
            regions: regions,
            spacing: spacing,
            origin: origin,
            memoryBudgetBytes: memoryBudgetBytes ?? previous.budgetBytes,
            instanceMemoryBudgetBytes: previous.instanceBudgetBytes,
            surfaceMemoryBudgetBytes: previous.surfaceData.budgetBytes
        )
        candidate.state.withLock { next in
            next.identity = previous.identity
            next.exportedInstanceRecordCount = previous.exportedInstanceRecordCount
            next.normalTiles = next.tiles
            next.tiles = next.tiles.filter { visible.contains(Self.region(containing: $0.key)) }
            next.tracksDirtyTiles = false
            next.dirty = []
            next.dirtySet = []
            next.dirtyHead = 0
            var affected: Set<TerrainTileCoordinate> = []
            var changed = previous.budgetBytes != next.budgetBytes
            for coordinate in Set(previous.tiles.keys).union(next.tiles.keys) {
                if Self.sameLayout(previous.tiles[coordinate], next.tiles[coordinate]) {
                    next.tiles[coordinate]?.revision = previous.tiles[coordinate]?.revision ?? 0
                } else {
                    affected.insert(coordinate); changed = true
                }
            }
            let normalCoordinates = Set(previous.normalTiles.keys).union(next.normalTiles.keys)
            for coordinate in normalCoordinates where !Self.sameLayout(previous.normalTiles[coordinate], next.normalTiles[coordinate]) {
                Self.includeNeighbors(coordinate, in: &affected)
                changed = true
            }
            for coordinate in Set(previous.pages.keys).union(next.pages.keys) {
                if previous.pages[coordinate]?.samples == next.pages[coordinate]?.samples {
                    if let old = previous.pages[coordinate] { next.pages[coordinate] = old }
                } else {
                    Self.includeNeighbors(coordinate, in: &affected)
                    changed = true
                }
            }
            // Compare decoded rows only when the resident set changes. Camera-only builds retain
            // immutable cell generations and never group or compare their placement arrays.
            for cell in Set(previous.instanceCells.keys).union(next.instanceCells.keys) {
                if previous.instanceCells[cell]?.records == next.instanceCells[cell]?.records {
                    next.instanceCells[cell] = previous.instanceCells[cell]
                } else {
                    changed = true
                }
            }
            for cell in Set(previous.surfaceData.cells.keys).union(next.surfaceData.cells.keys) {
                if let old = previous.surfaceData.cells[cell], let new = next.surfaceData.cells[cell], new.hasSameValues(as: old) {
                    next.surfaceData.cells[cell] = old
                } else {
                    Self.includeNeighbors(cell, in: &affected)
                    changed = true
                }
            }
            next.revision = changed ? previous.revision &+ 1 : previous.revision
            for coordinate in affected { next.tiles[coordinate]?.revision = next.revision }
        }
        return candidate
    }

    /// Commits only after GPU meshes/collision are prepared, without discarding concurrent author edits.
    func commitResidency(_ candidate: TerrainHeightStorage, expectedRevision: UInt64) throws {
        guard spacing == candidate.spacing, origin == candidate.origin else {
            throw StorageError.invalidConfiguration
        }
        let next = candidate.state.withLock { $0 }
        try state.withLock { value in
            guard value.revision == expectedRevision else { throw StorageError.staleRevision }
            value = next
        }
    }

    private static func sameLayout(_ left: Tile?, _ right: Tile?) -> Bool {
        left?.width == right?.width && left?.depth == right?.depth
    }

    private static func includeNeighbors(_ coordinate: TerrainTileCoordinate, in affected: inout Set<TerrainTileCoordinate>) {
        for z in -1...1 { for x in -1...1 { affected.insert(.init(x: coordinate.x + x, z: coordinate.z + z)) } }
    }
}

extension TerrainHeightStorage {
    private static func markSample(_ point: TerrainGridPoint, state: inout State) {
        // A sample changes heights at itself and normals one grid step away. Shared edge
        // vertices also belong to the tile before their canonical page owner.
        for z in floorDiv(point.z - 2, by: cellsPerTile)...floorDiv(point.z + 1, by: cellsPerTile) {
            for x in floorDiv(point.x - 2, by: cellsPerTile)...floorDiv(point.x + 1, by: cellsPerTile) {
                let coordinate = TerrainTileCoordinate(x: x, z: z)
                guard let tile = state.tiles[coordinate], point.x >= x * cellsPerTile - 1,
                    point.x <= x * cellsPerTile + tile.width + 1, point.z >= z * cellsPerTile - 1,
                    point.z <= z * cellsPerTile + tile.depth + 1
                else { continue }
                mark(coordinate, state: &state)
            }
        }
    }

    /// Copies metadata once and touched Float pages on write. Live storage is committed only after
    /// the source system has prepared the complete corresponding render/collision generation.
    func stagedHeights(_ updates: [TerrainHeightUpdate], expectedRevision: UInt64) throws -> (storage: TerrainHeightStorage, delta: TerrainHeightDelta) {
        guard updates.count <= Terrain3DHeightEdit.maximumUpdates else { throw TerrainHeightEditError.tooManyUpdates }
        let previous = try state.withLock { value in
            guard value.revision == expectedRevision else { throw TerrainHeightEditError.staleRevision }
            return value
        }
        var seen: Set<TerrainGridPoint> = []
        var changes: [TerrainHeightChange] = []
        var pageCounts: [TerrainTileCoordinate: Int] = [:]
        seen.reserveCapacity(updates.count)
        changes.reserveCapacity(updates.count)
        for (index, update) in updates.enumerated() {
            if index % 1_024 == 0 { try Task.checkCancellation() }
            guard seen.insert(update.point).inserted else { throw TerrainHeightEditError.duplicateSample }
            guard update.height.isFinite else { throw TerrainHeightEditError.invalidHeight }
            guard Self.isValid(update.point) else { throw TerrainHeightEditError.invalidCoordinate }
            guard Self.containsSample(update.point, state: previous) else { throw TerrainHeightEditError.missingSurface }
            let old = Self.read(update.point, state: previous)
            guard old != update.height else { continue }
            changes.append(.init(point: update.point, previousHeight: old, height: update.height))
            let address = Self.locate(update.point).page
            let count = pageCounts[address] ?? previous.pages[address]?.nonzeroCount ?? 0
            pageCounts[address] = count + (old == 0 ? 1 : 0) - (update.height == 0 ? 1 : 0)
        }
        var pageCount = previous.pages.count
        for (address, count) in pageCounts {
            if previous.pages[address] == nil && count > 0 { pageCount += 1 }
            if previous.pages[address] != nil && count == 0 { pageCount -= 1 }
        }
        guard pageCount <= previous.budgetBytes / Self.pageBytes else { throw TerrainHeightEditError.heightBudgetExceeded }
        changes.sort { left, right in left.point.z == right.point.z ? left.point.x < right.point.x : left.point.z < right.point.z }
        let candidate = try TerrainHeightStorage(spacing: spacing, origin: origin, memoryBudgetBytes: previous.budgetBytes)
        try candidate.state.withLock { value in
            value = previous
            // Free complete pages first, so a transaction can exchange pages within one budget.
            for (address, count) in pageCounts where count == 0 { value.pages.removeValue(forKey: address) }
            for (index, change) in changes.enumerated() {
                if index % 1_024 == 0 { try Task.checkCancellation() }
                _ = try Self.write(change.height, at: change.point, budget: value.budgetBytes, state: &value)
            }
            if !changes.isEmpty {
                value.revision &+= 1
                for change in changes { Self.markSample(change.point, state: &value) }
            }
        }
        try Task.checkCancellation()
        return (candidate, .init(changes: changes, previousRevision: expectedRevision, revision: candidate.revision))
    }
}

extension TerrainHeightStorage {
    /// Shallow immutable input for a worker; only later writes copy the affected Float pages.
    func snapshotForBrush(expectedRevision: UInt64) throws -> TerrainHeightStorage {
        var captured = try state.withLock { value in
            guard value.revision == expectedRevision else { throw TerrainHeightEditError.staleRevision }
            return value
        }
        captured.tracksDirtyTiles = false
        captured.dirty = []
        captured.dirtySet = []
        captured.dirtyHead = 0
        let copy = try TerrainHeightStorage(spacing: spacing, origin: origin, memoryBudgetBytes: captured.budgetBytes)
        copy.state.withLock { $0 = captured }
        return copy
    }
}

extension TerrainHeightStorage {
    /// Reads immutable canonical coverage for brush stencils, including non-rendered normal halos.
    func heightForBrush(at point: TerrainGridPoint) -> Float? {
        state.withLock { value in
            Self.containsSample(point, state: value, includeNormalCoverage: true) ? Self.read(point, state: value) : nil
        }
    }

    /// Reuses the renderer's one-sided and halo-aware derivative convention exactly.
    func normalForBrush(at point: TerrainGridPoint, includeNormalCoverage: Bool = false) -> Vector3? {
        state.withLock { value in
            guard Self.containsSample(point, state: value, includeNormalCoverage: includeNormalCoverage) else {
                return nil
            }
            return normal(x: point.x, z: point.z, state: value)
        }
    }
}

extension TerrainHeightStorage {
    /// A private query view over complete authored coverage; live draw coverage remains unchanged.
    func editingSnapshot(regions: Set<TerrainRegionCoordinate>, expectedRevision: UInt64) throws -> TerrainHeightStorage {
        let copy = try snapshotForBrush(expectedRevision: expectedRevision)
        copy.state.withLock { value in
            for (coordinate, tile) in value.tiles { value.normalTiles[coordinate] = tile }
            for (coordinate, tile) in value.normalTiles where regions.contains(Self.region(containing: coordinate)) {
                value.tiles[coordinate] = tile
            }
        }
        return copy
    }

    /// Retains edited hidden declarations for saving/queries while removing temporary query-only draw tiles.
    func restoreDrawCoverage(_ regions: Set<TerrainRegionCoordinate>) {
        state.withLock { value in
            for (coordinate, tile) in value.tiles { value.normalTiles[coordinate] = tile }
            value.tiles = value.tiles.filter { regions.contains(Self.region(containing: $0.key)) }
        }
    }
}
