import AdaAssets
import Math

/// Worker-only ownership selection. A complete height tile is replaced as one surface.
struct TerrainVolumeTilePlan {
    let tiles: [TerrainTileCoordinate: [TerrainVolumeBrickCoordinate]]
    let required: [TerrainVolumeBrickCoordinate]

    init(storage: TerrainHeightStorage, field: TerrainVolumeField, maximumBricks: Int) throws {
        let document = field.document, bounds = field.volumeOperandBounds
        let ratio = Double(storage.spacing) / Double(document.cellSize)
        guard ratio >= 1, ratio <= 64, ratio.rounded() == ratio else { throw TerrainVolumeFieldError.invalidConfiguration }
        let side = Double(document.cellSize) * 32, padding = max(Double(storage.spacing) * 2, Double(document.cellSize) * 3)
        var tiles: [TerrainTileCoordinate: [TerrainVolumeBrickCoordinate]] = [:]
        var required: Set<TerrainVolumeBrickCoordinate> = []
        func address(_ point: Double, origin: Float) throws -> Int32 {
            let value = ((point - Double(origin)) / side).rounded(.down)
            guard value.isFinite, value >= -32_768, value < 32_768 else { throw TerrainVolumeFieldError.invalidCoordinate }
            return Int32(value)
        }
        for coordinate in storage.tileCoordinates {
            try Task.checkCancellation()
            let lowX = Double(storage.origin.x) + Double(coordinate.x * 64) * Double(storage.spacing)
            let lowZ = Double(storage.origin.y) + Double(coordinate.z * 64) * Double(storage.spacing)
            let highX = lowX + 64 * Double(storage.spacing), highZ = lowZ + 64 * Double(storage.spacing)
            let relevant = bounds.filter {
                Double($0.min.x) - padding <= highX && Double($0.max.x) + padding >= lowX
                    && Double($0.min.z) - padding <= highZ && Double($0.max.z) + padding >= lowZ
            }
            guard !relevant.isEmpty else { continue }
            guard let snapshot = storage.snapshot(of: coordinate), snapshot.cellCountX == 64, snapshot.cellCountZ == 64 else {
                throw TerrainVolumeFieldError.invalidConfiguration
            }
            // Exact grid/refinement and brick-aligned tile edges preserve the untouched base planes.
            for (point, origin) in [(lowX, document.origin.x), (highX, document.origin.x), (lowZ, document.origin.z), (highZ, document.origin.z)] {
                let value = (point - Double(origin)) / side
                guard value.isFinite, value.rounded() == value else { throw TerrainVolumeFieldError.invalidConfiguration }
            }
            var lowY = Double(snapshot.heights.min() ?? 0), highY = Double(snapshot.heights.max() ?? 0)
            for bound in relevant { lowY = min(lowY, Double(bound.min.y)); highY = max(highY, Double(bound.max.y)) }
            let firstX = try address(lowX, origin: document.origin.x), lastX = try address(highX, origin: document.origin.x) - 1
            let firstZ = try address(lowZ, origin: document.origin.z), lastZ = try address(highZ, origin: document.origin.z) - 1
            let firstY = try address(lowY - padding, origin: document.origin.y), lastY = try address(highY + padding, origin: document.origin.y)
            let width = Int(lastX - firstX + 1), height = Int(lastY - firstY + 1), depth = Int(lastZ - firstZ + 1)
            guard width > 0, height > 0, depth > 0, width <= maximumBricks,
                height <= maximumBricks / width, depth <= maximumBricks / width / height else { throw TerrainVolumeFieldError.memoryBudgetExceeded }
            var addresses: [TerrainVolumeBrickCoordinate] = []
            for z in firstZ...lastZ {
                for y in firstY...lastY {
                    for x in firstX...lastX {
                        let brick = TerrainVolumeBrickCoordinate(x: x, y: y, z: z)
                        required.insert(brick)
                        guard required.count <= maximumBricks else { throw TerrainVolumeFieldError.memoryBudgetExceeded }
                        addresses.append(brick)
                    }
                }
            }
            tiles[coordinate] = addresses.sorted()
        }
        self.tiles = tiles; self.required = required.sorted()
    }
}
