@_spi(Internal) @testable import AdaRender
import Foundation
import Math
import Testing

@Suite("Meshlet CPU data")
struct MeshletGeometryTests {
    private let positions: [Vector3] = [[-1, 0, 0], [1, 0, 0], [0, 1, 0]]

    @Test func cachedAggregateBoundsConservativelyContainEveryCluster() throws {
        let vertices: [Vector3] = (0..<90).map { index in
            let x: Float = Float(index) * 0.37 - 10
            let y: Float = Float(index % 5) * 0.13
            let z: Float = Float(index % 7) * -0.21
            return Vector3(x, y, z)
        }
        let geometry = try MeshletGeometry.scan(positions: vertices, indices: (0..<90).map(UInt32.init))
        let bounds = try #require(geometry.bounds)
        for cluster in geometry.clusters {
            #expect(bounds.min.x <= cluster.minimum.x && bounds.min.y <= cluster.minimum.y && bounds.min.z <= cluster.minimum.z)
            #expect(bounds.max.x >= cluster.maximum.x && bounds.max.y >= cluster.maximum.y && bounds.max.z >= cluster.maximum.z)
        }
        #expect(try MeshletGeometry.scan(positions: [], indices: []).bounds == nil)
    }

    @Test func scanPreservesSequenceWindingMultiplicityAndVertexLimits() throws {
        let vertices = (0..<240).map { Vector3(Float($0), Float($0 % 3), 0) }
        var indices = (0..<240).map(UInt32.init)
        indices += [0, 0, 0, 2, 1, 0, 2, 1, 0]
        let geometry = try MeshletGeometry.scan(positions: vertices, indices: indices)
        #expect(geometry.indices == indices)
        #expect(geometry.clusters.count > 1)
        #expect(geometry.clusters.reduce(0) { $0 + $1.indexCount } == indices.count)
        var next = 0
        for cluster in geometry.clusters {
            #expect(cluster.firstIndex == next)
            #expect(cluster.indexCount % 3 == 0 && cluster.indexCount <= 96 * 3)
            let ids = indices[cluster.firstIndex..<(cluster.firstIndex + cluster.indexCount)]
            #expect(Set(ids).count <= 64)
            for id in ids {
                let p = vertices[Int(id)]
                #expect(p.x >= cluster.minimum.x && p.y >= cluster.minimum.y && p.z >= cluster.minimum.z)
                #expect(p.x <= cluster.maximum.x && p.y <= cluster.maximum.y && p.z <= cluster.maximum.z)
            }
            next += cluster.indexCount
        }
        let copied = geometry
        #expect(copied.id == geometry.id)
        let rebuilt = try MeshletGeometry.scan(positions: vertices, indices: indices)
        #expect(rebuilt.id != geometry.id && rebuilt.clusters == geometry.clusters)
    }

    @Test(arguments: [64, 96, 126])
    func profilesBoundRepeatedAndDegenerateTriangles(maximum: Int) throws {
        let triangle: [UInt32] = [0, 0, 0, 0, 1, 2]
        let indices: [UInt32] = Array(repeating: triangle, count: 150).flatMap { $0 }
        let geometry = try MeshletGeometry.scan(positions: positions, indices: indices, maximumTriangles: maximum)
        #expect(geometry.indices == indices)
        #expect(geometry.clusters.count == (300 + maximum - 1) / maximum)
        #expect(geometry.clusters.allSatisfy { $0.indexCount / 3 <= maximum })
        #expect(try MeshletGeometry.scan(positions: [], indices: []).clusters.isEmpty)
    }

    @Test func rejectsInvalidGeometryAndUnconservativeClusters() throws {
        #expect(throws: MeshletDataError.self) { try MeshletGeometry.scan(positions: positions, indices: [0, 1]) }
        #expect(throws: MeshletDataError.self) { try MeshletGeometry.scan(positions: positions, indices: [0, 1, 3]) }
        #expect(throws: MeshletDataError.self) { try MeshletGeometry.scan(positions: [[.nan, 0, 0]], indices: [0, 0, 0]) }
        #expect(throws: MeshletDataError.self) { try MeshletGeometry.scan(positions: positions, indices: [0, 1, 2], maximumVertices: 2) }
        #expect(throws: MeshletDataError.self) {
            try MeshletGeometry(clusters: [.init(firstIndex: 0, indexCount: 3, minimum: .zero, maximum: .one)], indices: [0, 1, 2], positions: positions)
        }
        #expect(throws: MeshletDataError.self) {
            try MeshletGeometry(clusters: [], indices: [0, 1, 2], positions: positions)
        }
    }

    @Test func sidecarRoundTripChecksSourceAndRejectsCorruption() throws {
        let indices: [UInt32] = [0, 1, 2, 2, 1, 0]
        let geometry = try MeshletGeometry.scan(positions: positions, indices: indices)
        // Shared with the offline Python tool's canonical float32/uint32 byte contract.
        #expect(geometry.sourceDigest == 0x51c6a434335c0f1d)
        let source = MeshletSidecar(parts: [.init(meshIndex: 3, partIndex: 7, geometry: geometry)])
        let data = try source.encoded()
        #expect(Array(data.prefix(8)) == Array("ADAMSHL1".utf8))
        let decoded = try MeshletSidecar(data: data)
        let restored = try #require(try decoded.geometry(meshIndex: 3, partIndex: 7, positions: positions, indices: indices))
        #expect(restored.clusters == geometry.clusters && restored.indices == indices)
        #expect(try decoded.geometry(meshIndex: 0, partIndex: 0, positions: positions, indices: indices) == nil)
        #expect(throws: MeshletDataError.self) {
            try decoded.geometry(meshIndex: 3, partIndex: 7, positions: positions.map { $0 + Vector3(0, 0, 1) }, indices: indices)
        }
        #expect(throws: MeshletDataError.self) {
            try decoded.geometry(meshIndex: 3, partIndex: 7, positions: positions, indices: [0, 2, 1, 2, 1, 0])
        }
        for length in [0, 7, 23, data.count - 1] {
            #expect(throws: MeshletDataError.self) { try MeshletSidecar(data: Data(data.prefix(length))) }
        }
        var trailing = data
        trailing.append(0)
        #expect(throws: MeshletDataError.self) { try MeshletSidecar(data: trailing) }
        var invalidBounds = data
        // First cluster minimum X starts after the 24-byte header + 28-byte record + two uints.
        invalidBounds.replaceSubrange(60..<64, with: [0, 0, 192, 127])
        #expect(throws: MeshletDataError.self) { try MeshletSidecar(data: invalidBounds) }
        let duplicate = MeshletSidecar(parts: source.parts + source.parts)
        #expect(throws: MeshletDataError.self) { try duplicate.encoded() }
    }
}
