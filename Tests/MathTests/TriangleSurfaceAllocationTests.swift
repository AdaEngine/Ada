@testable import Math
import Testing

@Suite("Surface index construction staging admission")
struct TriangleSurfaceAllocationTests {
    @Test("An allowance covering only three triangle arrays cannot cover recursive sorting plus hierarchy nodes")
    func recursiveStaging() throws {
        var positions: [Vector3] = [], indices: [UInt32] = []
        for z in 0...3 { for x in 0...3 { positions.append([Float(x), 0, Float(z)]) } }
        for z in 0..<3 {
            for x in 0..<3 {
                let a = UInt32(z * 4 + x)
                indices.append(contentsOf: [a, a + 4, a + 1, a + 1, a + 4, a + 5])
            }
        }
        let triangles = indices.count / 3
        let incompleteAllowance = triangles * MemoryLayout<ScalarMeshTriangle>.stride * 3
        #expect(throws: TriangleSurfaceQueryError.memoryBudgetExceeded) {
            try TriangleSurfaceIndex(positions: positions, indices: indices, maximumBytes: incompleteAllowance)
        }
        let complete = try? TriangleSurfaceIndex(positions: positions, indices: indices, maximumBytes: triangles * TriangleSurfaceIndex.bytesPerTriangle)
        #expect(complete != nil)
    }
}
