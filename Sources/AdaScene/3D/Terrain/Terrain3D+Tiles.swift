import AdaECS
@_spi(Internal) import AdaRender
import Math

/// A tile address in a terrain's local X/Z grid, independent of the camera.
public struct TerrainTileCoordinate: Codable, Hashable, Sendable, Comparable {
    public var x: Int
    public var z: Int

    public init(x: Int, z: Int) {
        self.x = x
        self.z = z
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.z == rhs.z ? lhs.x < rhs.x : lhs.z < rhs.z
    }
}

/// One terrain mesh tile. Positions and UVs retain the parent terrain's local coordinates.
public struct TerrainMeshTile: Sendable {
    public let coordinate: TerrainTileCoordinate
    public let descriptor: MeshDescriptor
}

/// Identifies generated terrain tiles; these are transient children of the authored terrain.
public struct TerrainTile3DComponent: Component {
    public let coordinate: TerrainTileCoordinate

    public init(coordinate: TerrainTileCoordinate) {
        self.coordinate = coordinate
    }
}

extension Terrain3D {
    /// Default tile width in heightfield cells. Boundary samples are shared by adjacent tiles.
    public static let defaultTileCellCount = 64

    /// Produces independently replaceable meshes with the same surface as the legacy heightfield.
    public func meshTiles(cellCount: Int = Terrain3D.defaultTileCellCount) throws -> [TerrainMeshTile] {
        try validate()
        guard (1...256).contains(cellCount) else { throw ValidationError.invalidHeightField }
        var result: [TerrainMeshTile] = []
        for z in stride(from: 0, to: resolution - 1, by: cellCount) {
            for x in stride(from: 0, to: resolution - 1, by: cellCount) {
                result.append(makeMeshTile(x: x, z: z, cellCount: cellCount))
            }
        }
        return result
    }

    /// Builds a single tile without constructing the rest of the terrain. Invalid addresses throw.
    public func meshTile(at coordinate: TerrainTileCoordinate, cellCount: Int = Terrain3D.defaultTileCellCount) throws -> TerrainMeshTile {
        try validate()
        guard (1...256).contains(cellCount), coordinate.x >= 0, coordinate.z >= 0,
            coordinate.x <= (resolution - 2) / cellCount, coordinate.z <= (resolution - 2) / cellCount
        else {
            throw ValidationError.invalidHeightField
        }
        return makeMeshTile(x: coordinate.x * cellCount, z: coordinate.z * cellCount, cellCount: cellCount)
    }

    private func makeMeshTile(x startX: Int, z startZ: Int, cellCount: Int) -> TerrainMeshTile {
        let endX = min(resolution - 1, startX + cellCount)
        let endZ = min(resolution - 1, startZ + cellCount)
        let width = endX - startX + 1
        let count = width * (endZ - startZ + 1)
        let step = size / Float(resolution - 1)
        var positions: [Vector3] = []
        var normals: [Vector3] = []
        var uvs: [Vector2] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(count)
        normals.reserveCapacity(count)
        uvs.reserveCapacity(count)
        indices.reserveCapacity((width - 1) * (endZ - startZ) * 6)
        for z in startZ...endZ {
            for x in startX...endX {
                let position = Vector3(Float(x) * step - size / 2, heights[z * resolution + x], Float(z) * step - size / 2)
                positions.append(position)
                uvs.append(Vector2(position.x / size + 0.5, position.z / size + 0.5))
                // Read across tile borders so shared vertices have identical smooth normals.
                let left = max(0, x - 1), right = min(resolution - 1, x + 1)
                let back = max(0, z - 1), front = min(resolution - 1, z + 1)
                let dx = (heights[z * resolution + right] - heights[z * resolution + left]) / (Float(right - left) * step)
                let dz = (heights[front * resolution + x] - heights[back * resolution + x]) / (Float(front - back) * step)
                normals.append(Vector3(-dx, 1, -dz).normalized)
                if x < endX, z < endZ {
                    let a = UInt32((z - startZ) * width + x - startX)
                    let b = a + 1, c = a + UInt32(width), d = c + 1
                    indices.append(contentsOf: [a, c, b, b, c, d])
                }
            }
        }
        let coordinate = TerrainTileCoordinate(x: startX / cellCount, z: startZ / cellCount)
        var descriptor = MeshDescriptor(name: "Terrain Tile \(coordinate.x),\(coordinate.z)")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.indicies = indices
        return TerrainMeshTile(coordinate: coordinate, descriptor: descriptor)
    }
}
