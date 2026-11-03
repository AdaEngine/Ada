@_spi(Internal) @testable import AdaRender
import Foundation
import Math
import Testing

@Suite("Meshlet adaptive LOD data")
struct MeshletLODGeometryTests {
    private func fixture() throws -> (positions: [Vector3], source: [UInt32], hierarchy: MeshletLODGeometry) {
        var positions: [Vector3] = []
        for y in 0..<3 { for x in 0..<3 { positions.append(Vector3(Float(x - 1), Float(y - 1), 0)) } }
        var source: [UInt32] = []
        for x in 0..<2 { for y in 0..<2 {
            let a = UInt32(y * 3 + x)
            source += [a, a + 1, a + 3, a + 1, a + 4, a + 3]
        } }
        let coarse: [UInt32] = [0, 2, 6, 2, 8, 6]
        let flat = try MeshletGeometry.scan(positions: positions, indices: source + coarse, maximumTriangles: 2)
        let nodes: [MeshletLODNode] = [
            .init(parent: 2, firstChild: 0, childCount: 0, firstCluster: 0, clusterCount: 2,
                  minimum: [-1, -1, 0], maximum: [0, 1, 0], error: 0, firstSourceIndex: 0, sourceIndexCount: 12),
            .init(parent: 2, firstChild: 0, childCount: 0, firstCluster: 2, clusterCount: 2,
                  minimum: [0, -1, 0], maximum: [1, 1, 0], error: 0, firstSourceIndex: 12, sourceIndexCount: 12),
            .init(parent: nil, firstChild: 0, childCount: 2, firstCluster: 4, clusterCount: 1,
                  minimum: [-1, -1, 0], maximum: [1, 1, 0], error: 0.1, firstSourceIndex: 0, sourceIndexCount: 24, level: 1),
        ]
        let hierarchy = try MeshletLODGeometry(positions: positions, sourceIndices: source, geometry: flat, nodes: nodes, roots: [2])
        return (positions, source, hierarchy)
    }

    @Test func hierarchyHasExactLeavesAndActuallySmallerParentCut() throws {
        let value = try fixture(), hierarchy = value.hierarchy
        #expect(hierarchy.baseIndexCount == 24)
        #expect(hierarchy.geometry.indices.count == 30)
        #expect(hierarchy.nodes[2].level == 1 && hierarchy.nodes[2].error > 0)
        var exact: [UInt32] = []
        for node in hierarchy.nodes.prefix(2) {
            for cluster in hierarchy.geometry.clusters[node.firstCluster..<(node.firstCluster + node.clusterCount)] {
                exact += hierarchy.geometry.indices[cluster.firstIndex..<(cluster.firstIndex + cluster.indexCount)]
            }
        }
        #expect(exact == value.source)
        let coarseCluster = hierarchy.geometry.clusters[4]
        #expect(coarseCluster.indexCount == 6 && coarseCluster.indexCount < hierarchy.baseIndexCount)
        #expect(hierarchy.matches(positions: value.positions, indices: value.source))
        #expect(!hierarchy.matches(positions: value.positions.map { $0 + Vector3(0, 0, 1) }, indices: value.source))
    }

    @Test func additiveSidecarRoundTripsAndRejectsStaleCorruptOrOverlappingRoots() throws {
        let value = try fixture()
        let file = MeshletLODSidecar(parts: [.init(meshIndex: 0, partIndex: 0, geometry: value.hierarchy)], maximumTriangles: 2)
        let encoded = try file.encoded()
        let decoded = try MeshletLODSidecar(data: encoded)
        let result = try #require(try decoded.geometry(meshIndex: 0, partIndex: 0, positions: value.positions, indices: value.source))
        #expect(result.roots == [2] && result.geometry.indices == value.hierarchy.geometry.indices)
        #expect(result.id != value.hierarchy.id)
        #expect(throws: MeshletDataError.self) {
            try decoded.geometry(meshIndex: 0, partIndex: 0, positions: value.positions, indices: Array(value.source.reversed()))
        }
        #expect(throws: MeshletDataError.self) { try MeshletLODSidecar(data: Data(encoded.dropLast())) }
        var badVersion = encoded
        badVersion.replaceSubrange(8..<12, with: [255, 255, 255, 255])
        #expect(throws: MeshletDataError.self) { try MeshletLODSidecar(data: badVersion) }
        #expect(throws: MeshletDataError.self) {
            try MeshletLODGeometry(positions: value.positions, sourceIndices: value.source,
                geometry: value.hierarchy.geometry, nodes: value.hierarchy.nodes, roots: [2, 0])
        }
        var nodes = value.hierarchy.nodes
        let root = nodes[2]
        nodes[2] = .init(parent: nil, firstChild: 1, childCount: 2, firstCluster: root.firstCluster, clusterCount: root.clusterCount,
            minimum: root.minimum, maximum: root.maximum, error: root.error,
            firstSourceIndex: 0, sourceIndexCount: root.sourceIndexCount, level: 1)
        #expect(throws: MeshletDataError.self) {
            try MeshletLODGeometry(positions: value.positions, sourceIndices: value.source, geometry: value.hierarchy.geometry, nodes: nodes, roots: [2])
        }
    }
}
