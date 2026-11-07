@_spi(Internal) import AdaRender
@testable import AdaScene
import Math
import Testing

@Suite("Terrain mesh tiles")
struct TerrainTileTests {
    @Test("Splitting a legacy patch preserves every triangle and shared border normal")
    func splitsWithoutChangingSurface() throws {
        var terrain = Terrain3D(resolution: 7, size: 6)
        for z in 0..<7 {
            for x in 0..<7 { terrain.heights[z * 7 + x] = Float(x * x + z) / 10 }
        }
        let tiles = try terrain.meshTiles(cellCount: 3)
        #expect(
            tiles.map(\.coordinate) == [
                .init(x: 0, z: 0), .init(x: 1, z: 0), .init(x: 0, z: 1), .init(x: 1, z: 1),
            ]
        )
        #expect(tiles.allSatisfy { $0.descriptor.positions.count == 16 })
        #expect(tiles.reduce(0) { $0 + $1.descriptor.indicies.count } == 6 * 6 * 6)
        let original = try terrain.meshDescriptor()
        let sourcePositions = original.positions.elements
        let sourceNormals = original.normals?.elements ?? []
        let sourceUVs = original.textureCoordinates?.elements ?? []
        for tile in tiles {
            let positions = tile.descriptor.positions.elements
            let normals = try #require(tile.descriptor.normals?.elements)
            let uvs = try #require(tile.descriptor.textureCoordinates?.elements)
            for index in positions.indices {
                let source = try #require(sourcePositions.firstIndex(of: positions[index]))
                #expect(normals[index] == sourceNormals[source])
                #expect(uvs[index] == sourceUVs[source])
            }
            for index in stride(from: 0, to: tile.descriptor.indicies.count, by: 3) {
                let indices = tile.descriptor.indicies
                let a = positions[Int(indices[index])]
                let b = positions[Int(indices[index + 1])]
                let c = positions[Int(indices[index + 2])]
                #expect((b - a).cross(c - a).y > 0)
            }
        }
    }

    @Test("Remainder tiles cover non-divisible grids without adding cells")
    func remainderAndLimits() throws {
        let terrain = Terrain3D(resolution: 8, size: 7)
        let tiles = try terrain.meshTiles(cellCount: 3)
        #expect(tiles.count == 9)
        #expect(tiles.last?.descriptor.positions.count == 4)
        #expect(tiles.reduce(0) { $0 + $1.descriptor.indicies.count } == 7 * 7 * 6)
        #expect(throws: Terrain3D.ValidationError.self) { try terrain.meshTiles(cellCount: 0) }
        #expect(throws: Terrain3D.ValidationError.self) { try terrain.meshTiles(cellCount: Int.max) }
        #expect(try Terrain3D(resolution: 2).meshTiles().count == 1)
    }
}
