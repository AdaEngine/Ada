import Math

/// Bounded camera focus policy shared by runtime tile builds. Distances are terrain-local in X/Z.
enum TerrainCameraLOD {
    static let maximumCameras = 16

    static func select(
        storage: TerrainHeightStorage,
        coordinates: [TerrainTileCoordinate],
        cameraPositions: [Vector3],
        inverse: Transform3D,
        maximumLevel: Int,
        distance: Float,
        previous: [TerrainTileCoordinate: TerrainLODSelection]
    ) throws -> [TerrainTileCoordinate: TerrainLODSelection] {
        let local = cameraPositions.compactMap { position -> Vector2? in
            let value = (inverse * Vector4(position, 1)).xyz
            return value.x.isFinite && value.z.isFinite ? Vector2(value.x, value.z) : nil
        }
        var proposed: [TerrainTileCoordinate: Int] = [:]
        var partial: Set<TerrainTileCoordinate> = []
        proposed.reserveCapacity(coordinates.count)
        for coordinate in coordinates {
            guard let cells = storage.tileCellCounts(at: coordinate) else { continue }
            if cells.x != 64 || cells.z != 64 { partial.insert(coordinate) }
            let minX = Double(storage.origin.x) + Double(coordinate.x * 64) * Double(storage.spacing)
            let minZ = Double(storage.origin.y) + Double(coordinate.z * 64) * Double(storage.spacing)
            let maxX = minX + Double(cells.x) * Double(storage.spacing)
            let maxZ = minZ + Double(cells.z) * Double(storage.spacing)
            var nearest = Double.infinity
            for camera in local {
                let dx = max(0, max(minX - Double(camera.x), Double(camera.x) - maxX))
                let dz = max(0, max(minZ - Double(camera.y), Double(camera.y) - maxZ))
                nearest = min(nearest, dx * dx + dz * dz)
            }
            var level = min(previous[coordinate]?.level ?? 0, maximumLevel)
            if local.isEmpty {
                level = 0
            } else {
                // Retain detail across a 15% band so small camera jitter does not recreate GPU buffers.
                let coarsen = previous[coordinate] == nil ? 1.0 : 1.15
                let refine = previous[coordinate] == nil ? 1.0 : 0.85
                while level < maximumLevel {
                    let threshold = Double(distance) * Double(1 << level) * coarsen
                    guard nearest > threshold * threshold else { break }
                    level += 1
                }
                while level > 0 {
                    let threshold = Double(distance) * Double(1 << (level - 1)) * refine
                    guard nearest < threshold * threshold else { break }
                    level -= 1
                }
            }
            proposed[coordinate] = level
        }
        return try TerrainLODBalancer.select(proposed: proposed, partialTiles: partial)
    }
}
