@_spi(Internal) import AdaRender
import Math

struct TerrainPreparedQuery: Sendable {
    let index: TriangleSurfaceIndex
    let chargedBytes: Int
}

/// One shared worker budget; failed admission never alters a previously published index.
struct TerrainSourceQueryPreparation {
    private let settings: TerrainSurfaceQuerySettings?
    private var remainingBytes: Int
    private var remainingWork: Int
    var isEnabled: Bool { settings != nil }
    private static let entryBytes = MemoryLayout<TerrainPreparedQuery>.stride * 3 + MemoryLayout<TerrainTileCoordinate>.stride * 2 + 128

    init(settings: TerrainSurfaceQuerySettings?) throws {
        try settings?.validate()
        self.settings = settings; remainingBytes = settings?.maximumResidentBytes ?? 0; remainingWork = settings?.maximumConstructionWork ?? 0
    }

    mutating func retain(_ query: TerrainPreparedQuery?) throws {
        guard isEnabled, let query else {
            return
        }
        guard query.chargedBytes <= remainingBytes else { throw TriangleSurfaceQueryError.memoryBudgetExceeded }
        remainingBytes -= query.chargedBytes
    }

    mutating func prepare(_ descriptor: MeshDescriptor, previous: TerrainPreparedQuery?, sameGeometry: Bool) throws -> TerrainPreparedQuery? {
        guard isEnabled else {
            return nil
        }
        if sameGeometry, let previous {
            try retain(previous)
            return previous
        }
        let count = descriptor.indicies.count / 3
        guard Self.entryBytes <= remainingBytes else { throw TriangleSurfaceQueryError.memoryBudgetExceeded }
        var available = remainingBytes - Self.entryBytes
        let copyBytes: Int
        if count == 0 { copyBytes = 0 } else {
            let vertices = descriptor.positions.count
            guard vertices <= available / MemoryLayout<Vector3>.stride else { throw TriangleSurfaceQueryError.memoryBudgetExceeded }
            copyBytes = vertices * MemoryLayout<Vector3>.stride
            available -= copyBytes
        }
        guard count <= available / TriangleSurfaceIndex.bytesPerTriangle else { throw TriangleSurfaceQueryError.memoryBudgetExceeded }
        let index = try TriangleSurfaceIndex(
            positions: count == 0 ? [] : descriptor.positions.elements,
            indices: descriptor.indicies,
            maximumBytes: available,
            maximumWork: remainingWork
        )
        let query = TerrainPreparedQuery(index: index, chargedBytes: index.chargedBytes + copyBytes + Self.entryBytes)
        guard index.constructionWork <= remainingWork else { throw TriangleSurfaceQueryError.workBudgetExceeded }
        remainingWork -= index.constructionWork
        try retain(query)
        return query
    }
}
