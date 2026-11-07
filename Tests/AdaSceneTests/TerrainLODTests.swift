@_spi(Internal) import AdaRender
import AdaScene
import Math
import Testing

@Suite("Terrain heightfield LOD")
struct TerrainLODTests {
    private struct EdgeVertex: Equatable {
        let position: Vector3
        let normal: Vector3
    }

    private func edge(_ mesh: MeshDescriptor, atX x: Float) throws -> [EdgeVertex] {
        var points: [Float: EdgeVertex] = [:]
        let normals = try #require(mesh.normals)
        for index in Set(mesh.indicies) {
            let point = mesh.positions.elements[Int(index)]
            if point.x == x { points[point.z] = .init(position: point, normal: normals.elements[Int(index)]) }
        }
        return points.keys.sorted().compactMap { points[$0] }
    }

    @Test("Coarse levels reduce geometry while retaining canonical sampled positions, normals and UVs")
    func downsamplesCanonicalSnapshot() throws {
        var terrain = Terrain3D(resolution: 65, size: 64)
        terrain.heights[32 * 65 + 32] = 17
        let storage = try TerrainHeightStorage(importing: terrain)
        let snapshot = try #require(storage.snapshot(of: .init(x: 0, z: 0)))
        let lod = try snapshot.meshLOD(level: 1)
        #expect(lod.level == 1)
        #expect(lod.coordinate == snapshot.coordinate && lod.revision == snapshot.revision)
        #expect(lod.descriptor.positions.elements.count == 1_089)
        #expect(lod.descriptor.indicies.count == 6_144)
        let original = snapshot.meshDescriptor()
        let originalUVs = try #require(original.textureCoordinates)
        let lodUVs = try #require(lod.descriptor.textureCoordinates)
        let originalNormals = try #require(original.normals)
        let lodNormals = try #require(lod.descriptor.normals)
        var canonical = true
        for (index, point) in lod.descriptor.positions.elements.enumerated() {
            let x = Int(point.x + 32), z = Int(point.z + 32)
            let source = z * 65 + x
            if point != original.positions.elements[source] || lodNormals.elements[index] != originalNormals.elements[source]
                || lodUVs.elements[index] != originalUVs.elements[source] {
                canonical = false
            }
        }
        #expect(canonical)
        let fine = try snapshot.meshLOD(level: 0)
        #expect(fine.descriptor.indicies == original.indicies)
    }

    @Test("An explicit coarse-side seam references the same nonlinear border vertices and normals as its fine neighbor")
    func stitchesNeighborGeometry() throws {
        let storage = try TerrainHeightStorage()
        try storage.allocateRegion(at: .init(x: 0, z: 0))
        for z in 0...64 { try storage.setHeight(Float((z * 7) % 11), at: .init(x: 64, z: z)) }
        let left = try #require(storage.snapshot(of: .init(x: 0, z: 0)))
        let right = try #require(storage.snapshot(of: .init(x: 1, z: 0)))
        let fine = try left.meshLOD(level: 1)
        let coarse = try right.meshLOD(level: 2, finerEdges: .minX)
        let fineEdge = try edge(fine.descriptor, atX: 64)
        let coarseEdge = try edge(coarse.descriptor, atX: 64)
        #expect(fineEdge.count == 33)
        #expect(coarseEdge == fineEdge)
    }

    @Test("Every edge/corner combination preserves upward nondegenerate coverage; partial tiles and invalid levels stay bounded")
    func cornerCoverageAndInputValidation() throws {
        var terrain = Terrain3D(resolution: 65, size: 64)
        terrain.heights[32 * 65 + 32] = 17
        let storage = try TerrainHeightStorage(importing: terrain)
        let snapshot = try #require(storage.snapshot(of: .init(x: 0, z: 0)))
        for level in 1...6 {
            for mask: UInt8 in 0...15 {
                let mesh = try snapshot.meshLOD(level: level, finerEdges: .init(rawValue: mask)).descriptor
                let positions = mesh.positions.elements
                var upward = true
                var area: Double = 0
                for offset in stride(from: 0, to: mesh.indicies.count, by: 3) {
                    let a = positions[Int(mesh.indicies[offset])]
                    let b = positions[Int(mesh.indicies[offset + 1])]
                    let c = positions[Int(mesh.indicies[offset + 2])]
                    let y = Double(b.z - a.z) * Double(c.x - a.x) - Double(b.x - a.x) * Double(c.z - a.z)
                    if y <= 0 { upward = false }
                    area += y / 2
                }
                #expect(upward)
                #expect(area == 4_096)
            }
        }
        #expect(throws: TerrainLODMeshError.self) { try snapshot.meshLOD(level: .max) }
        #expect(throws: TerrainLODMeshError.self) { try snapshot.meshLOD(level: -1) }
        #expect(throws: TerrainLODMeshError.self) { try snapshot.meshLOD(level: 0, finerEdges: .maxX) }
        #expect(throws: TerrainLODMeshError.self) { try snapshot.meshLOD(level: 1, finerEdges: .init(rawValue: 128)) }
        let partialStorage = try TerrainHeightStorage(importing: Terrain3D(resolution: 10, size: 9))
        let partial = try #require(partialStorage.snapshot(of: .init(x: 0, z: 0)))
        #expect(try partial.meshLOD(level: 4).level == 0)
        #expect(throws: TerrainLODMeshError.self) { try partial.meshLOD(level: 2, finerEdges: .minX) }
    }
}
