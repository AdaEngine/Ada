@testable import AdaScene
import Math
import Testing

@Suite("Finite terrain transition arithmetic")
struct TerrainVolumeSeamArithmeticTests {
    @Test("Split transition fans retain finite vertices when three finite world coordinates overflow a Float sum")
    func finiteFanCentroid() throws {
        let storage = try TerrainHeightStorage(spacing: 4e31, origin: [1.2e38, 1.2e38])
        try storage.allocateRegion(at: .init(x: 0, z: 0))
        let snapshot = try #require(storage.snapshot(of: .init(x: 0, z: 0)))
        let source = snapshot.meshDescriptor().positions.elements
        let a = source[32 * 65 + 1], b = source[33 * 65 + 1], c = source[32 * 65 + 2]
        let midpoint = Vector3(
            Float((Double(a.x) + Double(b.x)) / 2),
            Float((Double(a.y) + Double(b.y)) / 2),
            Float((Double(a.z) + Double(b.z)) / 2)
        )
        try #require(midpoint.z > a.z && midpoint.z < b.z)
        var positions = [a, midpoint, c], normals = Array(repeating: Vector3(0, 1, 0), count: 3), indices: [UInt32] = [0, 1, 2]
        let added = try TerrainVolumeSeamGeometry.conform(
            positions: &positions,
            normals: &normals,
            indices: &indices,
            snapshot: snapshot,
            edges: .minX,
            maximumTriangles: 4_096
        )
        #expect(added > 128, "The midpoint must split a transition triangle into a real fan")
        #expect(positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        #expect(normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }
}
