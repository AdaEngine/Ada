import AdaAssets
@_spi(Internal) import AdaRender
import Foundation

struct TerrainSourceVolume: Sendable {
    let resources: TerrainVolumeResources
    let meshes: [TerrainVolumePreparedMesh]
    let cache: TerrainVolumeCache
    let tiles: [TerrainTileCoordinate: TerrainVolumePreparedTile]
    let operandBytes: Int
}

struct TerrainSourceVolumeBuild: Sendable {
    let state: TerrainSourceVolume?
    let changed: Set<TerrainTileCoordinate>
    let chargedBytes: Int
    var tiles: [TerrainTileCoordinate: TerrainVolumePreparedTile] { state?.tiles ?? [:] }
}

enum TerrainSourceVolumes {
    static func prepare(storage: TerrainHeightStorage, residency: TerrainSourceResidency?, maximumBytes: Int) async throws -> TerrainSourceVolumeBuild {
        guard let residency else {
            return .init(state: nil, changed: [], chargedBytes: 0)
        }
        let previous = residency.volume
        let resources: TerrainVolumeResources?
        if let previous { resources = previous.resources } else { resources = try await residency.cache.loadVolumeResources() }
        guard let resources, resources.document.operations.contains(where: \.isEnabled) else {
            return .init(state: nil, changed: Set(previous?.tiles.keys ?? [:].keys), chargedBytes: 0)
        }
        let meshes: [TerrainVolumePreparedMesh]
        let operandBytes: Int
        if let previous { meshes = previous.meshes; operandBytes = previous.operandBytes } else {
            let active = resources.document.operations.filter { operation in
                guard operation.isEnabled, case .mesh = operation.operand else {
                    return false
                }
                return true
            }
            let perMesh = 32 * 1_024 * 1_024
            guard active.count <= maximumBytes / perMesh else { throw TerrainSourceError.meshBudgetExceeded }
            operandBytes = active.count * perMesh
            var prepared: [TerrainVolumePreparedMesh] = []
            for operation in active {
                prepared.append(try await resources.loadPreparedMesh(operationID: operation.id, maximumBytes: perMesh))
            }
            meshes = prepared
        }
        guard operandBytes <= maximumBytes else { throw TerrainSourceError.meshBudgetExceeded }
        let field = try TerrainVolumeField(
            document: resources.document,
            base: storage,
            preparedMeshes: meshes,
            interiorLayerID: residency.cache.manifest.materials?.fallbackLayerID,
            maximumMeshSampleWork: 256
        )
        let oldCache = try previous?.cache ?? TerrainVolumeCache()
        let plan = try TerrainVolumeTilePlan(storage: storage, field: field, maximumBricks: oldCache.maximumBricks)
        let cache = try oldCache.preparing(field: field, required: plan.required)
        var tiles: [TerrainTileCoordinate: TerrainVolumePreparedTile] = [:]
        var remaining = maximumBytes - operandBytes
        var changed = Set(previous?.tiles.keys ?? [:].keys).subtracting(plan.tiles.keys)
        let heightTiles = Set(storage.tileCoordinates)
        for coordinate in plan.tiles.keys.sorted() {
            guard let coordinates = plan.tiles[coordinate] else { continue }
            let generations = coordinates.compactMap { cache.brickGeneration(at: $0) }
            var edges: TerrainLODEdges = []
            for (dx, dz, edge) in [(0, -1, TerrainLODEdges.minZ), (0, 1, .maxZ), (-1, 0, .minX), (1, 0, .maxX)] {
                let neighbor = TerrainTileCoordinate(x: coordinate.x + dx, z: coordinate.z + dz)
                if heightTiles.contains(neighbor), plan.tiles[neighbor] == nil { edges.insert(edge) }
            }
            let tile: TerrainVolumePreparedTile
            if let old = previous?.tiles[coordinate], old.inputs == generations, old.heightfieldEdges == edges { tile = old } else {
                guard let snapshot = storage.snapshot(of: coordinate) else { throw TerrainSourceError.changedDuringBuild }
                tile = try TerrainVolumeTileGeometry.prepare(
                    coordinates: coordinates,
                    cache: cache,
                    field: field,
                    snapshot: snapshot,
                    heightfieldEdges: edges,
                    maximumBytes: remaining
                )
                changed.insert(coordinate)
            }
            guard tile.chargedBytes <= remaining else { throw TerrainSourceError.meshBudgetExceeded }
            remaining -= tile.chargedBytes; tiles[coordinate] = tile
        }
        return .init(
            state: .init(resources: resources, meshes: meshes, cache: cache, tiles: tiles, operandBytes: operandBytes),
            changed: changed,
            chargedBytes: maximumBytes - remaining
        )
    }
}
