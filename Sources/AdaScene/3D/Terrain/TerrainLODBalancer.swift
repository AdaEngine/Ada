import Foundation

/// A balanced tile level and the coarse-side boundaries that need additional vertices.
public struct TerrainLODSelection: Equatable, Sendable {
    public let level: Int
    public let finerEdges: TerrainLODEdges
}

public enum TerrainLODBalanceError: LocalizedError {
    case invalidLevel
    case invalidCoordinate
    case inputBudgetExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidLevel: "Terrain LOD proposals must be between 0 and 6"
        case .invalidCoordinate: "Terrain LOD tile address is outside the supported grid"
        case .inputBudgetExceeded: "Terrain LOD input exceeds 65536 tiles"
        }
    }
}

/// Refines proposed levels to satisfy neighbor seams without coarsening requested detail.
public enum TerrainLODBalancer {
    public static func select(
        proposed: [TerrainTileCoordinate: Int],
        fullDetailTiles: Set<TerrainTileCoordinate> = [],
        partialTiles: Set<TerrainTileCoordinate> = []
    ) throws -> [TerrainTileCoordinate: TerrainLODSelection] {
        guard proposed.count <= 65_536, fullDetailTiles.count <= 65_536, partialTiles.count <= 65_536 else { throw TerrainLODBalanceError.inputBudgetExceeded }
        for (coordinate, level) in proposed {
            try validate(coordinate)
            guard (0...6).contains(level) else { throw TerrainLODBalanceError.invalidLevel }
        }
        for coordinate in fullDetailTiles { try validate(coordinate) }
        for coordinate in partialTiles { try validate(coordinate) }
        var balanced = proposed
        for coordinate in fullDetailTiles where balanced[coordinate] != nil { balanced[coordinate] = 0 }
        for coordinate in partialTiles {
            if balanced[coordinate] != nil { balanced[coordinate] = 0 }
            neighbors(of: coordinate) { neighbor, _ in if balanced[neighbor] != nil { balanced[neighbor] = 0 } }
        }
        var queue = Array(balanced.keys)
        var queued = Set(queue)
        var cursor = 0
        // Levels only decrease, at most six times per tile. Propagate refinement without
        // allocating a neighbor array for every visit or depending on dictionary order.
        while cursor < queue.count {
            let coordinate = queue[cursor]
            cursor += 1
            queued.remove(coordinate)
            guard let level = balanced[coordinate] else { continue }
            neighbors(of: coordinate) { neighbor, _ in
                if let other = balanced[neighbor], other > level + 1 {
                    balanced[neighbor] = level + 1
                    if queued.insert(neighbor).inserted { queue.append(neighbor) }
                }
            }
            if cursor > 4_096, cursor > queue.count / 2 { queue.removeFirst(cursor); cursor = 0 }
        }
        var selections: [TerrainTileCoordinate: TerrainLODSelection] = [:]
        selections.reserveCapacity(balanced.count)
        for (coordinate, level) in balanced {
            var edges: TerrainLODEdges = []
            if level > 0 {
                neighbors(of: coordinate) { neighbor, edge in if balanced[neighbor] == level - 1 { edges.insert(edge) } }
            }
            selections[coordinate] = .init(level: level, finerEdges: edges)
        }
        return selections
    }

    private static func validate(_ coordinate: TerrainTileCoordinate) throws {
        guard (-16_384..<16_384).contains(coordinate.x), (-16_384..<16_384).contains(coordinate.z) else { throw TerrainLODBalanceError.invalidCoordinate }
    }

    private static func neighbors(of coordinate: TerrainTileCoordinate, visit: (TerrainTileCoordinate, TerrainLODEdges) -> Void) {
        visit(.init(x: coordinate.x - 1, z: coordinate.z), .minX)
        visit(.init(x: coordinate.x + 1, z: coordinate.z), .maxX)
        visit(.init(x: coordinate.x, z: coordinate.z - 1), .minZ)
        visit(.init(x: coordinate.x, z: coordinate.z + 1), .maxZ)
    }
}
