import Foundation
import Math

/// Opt-in query acceleration, bounded separately from render meshes and density residency.
public struct TerrainSurfaceQuerySettings: Codable, Equatable, Sendable {
    /// Conservative current-generation index and construction-staging allowance.
    public var maximumResidentBytes: Int
    /// Shared across all newly built indices in a source preparation.
    public var maximumConstructionWork: Int
    public init(maximumResidentBytes: Int = 256 * 1_024 * 1_024, maximumConstructionWork: Int = 67_108_864) {
        self.maximumResidentBytes = maximumResidentBytes; self.maximumConstructionWork = maximumConstructionWork
    }

    func validate() throws {
        guard (0...1_073_741_824).contains(maximumResidentBytes), (0...1_073_741_824).contains(maximumConstructionWork) else {
            throw TerrainSourceError.invalidConfiguration
        }
    }
}

public struct TerrainSurfaceQueryHit: Sendable {
    public let coordinate: TerrainTileCoordinate
    public let surface: TriangleSurfaceHit
    public var position: Vector3 { surface.position }
    public var normal: Vector3 { surface.normal }
    public var distance: Float { surface.distance }
    public var preciseDistance: Double { surface.preciseDistance }
}

/// Immutable terrain-local queries for one committed render/collision generation.
/// Holding a value retains that generation even while the source publishes a replacement.
public struct TerrainSurfaceQueries: Sendable {
    private struct Tile: Sendable {
        let coordinate: TerrainTileCoordinate
        let query: TerrainPreparedQuery
    }
    public let revision: UInt64
    public let chargedBytes: Int
    private let tiles: [Tile]
    public var tileCount: Int { tiles.count }

    init(revision: UInt64, queries: [TerrainTileCoordinate: TerrainPreparedQuery]) {
        self.revision = revision
        tiles = queries.keys.sorted().compactMap { coordinate in queries[coordinate].map { Tile(coordinate: coordinate, query: $0) } }
        chargedBytes = tiles.reduce(0) { $0 + $1.query.chargedBytes }
    }

    public func tileGeneration(at coordinate: TerrainTileCoordinate) -> UUID? { tiles.first { $0.coordinate == coordinate }?.query.index.generation }

    /// Ray direction is normalized; hits and distances are measured in terrain-local space.
    public func raycast(_ ray: Ray, maximumDistance: Float = .greatestFiniteMagnitude, maximumWork: Int = 1_048_576) throws -> TerrainSurfaceQueryHit? {
        var budget = try TriangleSurfaceQueryBudget(maximumWork: maximumWork)
        guard finite(ray.origin), finite(ray.direction), ray.direction != .zero, maximumDistance.isFinite, maximumDistance >= 0 else {
            throw TriangleSurfaceQueryError.invalidQuery
        }
        var result: TerrainSurfaceQueryHit?
        for tile in tiles {
            try budget.charge()
            let limit = min(maximumDistance, result.map { $0.distance.nextUp } ?? maximumDistance)
            if let hit = try tile.query.index.raycast(ray, maximumDistance: limit, budget: &budget), result == nil || hit.preciseDistance < (result?.preciseDistance ?? .infinity) {
                result = .init(coordinate: tile.coordinate, surface: hit)
            }
        }
        return result
    }

    public func closest(to point: Vector3, maximumDistance: Float = .greatestFiniteMagnitude, maximumWork: Int = 1_048_576) throws -> TerrainSurfaceQueryHit? {
        var budget = try TriangleSurfaceQueryBudget(maximumWork: maximumWork)
        guard finite(point), maximumDistance.isFinite, maximumDistance >= 0 else { throw TriangleSurfaceQueryError.invalidQuery }
        var result: TerrainSurfaceQueryHit?
        for tile in tiles {
            try budget.charge()
            let limit = min(maximumDistance, result.map { $0.distance.nextUp } ?? maximumDistance)
            if let hit = try tile.query.index.closest(to: point, maximumDistance: limit, budget: &budget), result == nil || hit.preciseDistance < (result?.preciseDistance ?? .infinity) {
                result = .init(coordinate: tile.coordinate, surface: hit)
            }
        }
        return result
    }

    private func finite(_ point: Vector3) -> Bool { point.x.isFinite && point.y.isFinite && point.z.isFinite }
}
