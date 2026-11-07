import Math
import Testing

@Suite("Bounded open triangle surface queries")
struct TriangleSurfaceQueryTests {
    private var positions: [Vector3] {
        [[-2, 0, -2], [2, 0, -2], [-2, 0, 2], [2, 0, 2], [-1, 3, -1], [1, 3, -1], [-1, 3, 1], [1, 3, 1]]
    }
    private var indices: [UInt32] { [0, 2, 1, 1, 2, 3, 4, 6, 5, 5, 6, 7] }

    @Test("Two-sided rays and closest points distinguish stacked surfaces and include exact shared edges")
    func stackedSurfaces() throws {
        let index = try #require(try? TriangleSurfaceIndex(positions: positions, indices: indices), "An open indexed terrain surface must build")
        let hit = try #require(try index.raycast(.init(origin: [0, 6, 0], direction: [0, -2, 0])))
        #expect(hit.position == [0, 3, 0] && abs(hit.distance - 3) < 1e-6)
        #expect(hit.normal.y > 0.999 && (2...3).contains(hit.triangleIndex))
        let underside = try #require(try index.raycast(.init(origin: [0, 1, 0], direction: [0, 4, 0])))
        #expect(underside.position.y == 3 && abs(underside.distance - 2) < 1e-6 && underside.normal.y > 0.999)
        let closest = try #require(try index.closest(to: [0.2, 2.6, 0.3]))
        #expect(abs(closest.position.y - 3) < 1e-6 && abs(closest.distance - 0.4) < 1e-5)
        #expect(try index.closest(to: [0.2, 2.6, 0.3], maximumDistance: 0.1) == nil)
        #expect(try index.raycast(.init(origin: [10, 6, 10], direction: [0, -1, 0])) == nil)
    }

    @Test("Empty surfaces stay empty while malformed input, unrepresentable indices and construction limits reject safely")
    func validationAndBudgets() throws {
        let empty = try #require(try? TriangleSurfaceIndex(positions: [], indices: []))
        #expect(try empty.raycast(.init(origin: .zero, direction: [0, 1, 0])) == nil)
        #expect(try empty.closest(to: .zero) == nil)
        #expect(throws: TriangleSurfaceQueryError.invalidMesh) { try TriangleSurfaceIndex(positions: [.zero], indices: [UInt32.max, 0, 0]) }
        #expect(throws: TriangleSurfaceQueryError.invalidMesh) { try TriangleSurfaceIndex(positions: [.zero, .zero, [1, 0, 0]], indices: [0, 1, 2]) }
        #expect(throws: TriangleSurfaceQueryError.invalidMesh) { try TriangleSurfaceIndex(positions: [[.infinity, 0, 0]], indices: [0, 0, 0]) }
        #expect(throws: TriangleSurfaceQueryError.memoryBudgetExceeded) { try TriangleSurfaceIndex(positions: positions, indices: indices, maximumBytes: 0) }
        #expect(throws: TriangleSurfaceQueryError.workBudgetExceeded) { try TriangleSurfaceIndex(positions: positions, indices: indices, maximumWork: 0) }
    }

    @Test("Ray and nearest queries share bounded work without publishing a partial result")
    func sharedWork() throws {
        let index = try #require(try? TriangleSurfaceIndex(positions: positions, indices: indices))
        let ray = Ray(origin: [0, 6, 0], direction: [0, -1, 0])
        var budget = try TriangleSurfaceQueryBudget(maximumWork: 6)
        #expect(try index.raycast(ray, budget: &budget) != nil)
        #expect(throws: TriangleSurfaceQueryError.workBudgetExceeded) { try index.raycast(ray, budget: &budget) }
        #expect(throws: TriangleSurfaceQueryError.workBudgetExceeded) { try index.closest(to: [0, 2.5, 0], maximumWork: 0) }
        #expect(throws: TriangleSurfaceQueryError.invalidQuery) { try index.raycast(.init(origin: .zero, direction: .zero)) }
        #expect(throws: TriangleSurfaceQueryError.invalidQuery) { try index.closest(to: [.nan, 0, 0]) }
    }

    @Test("A real twenty-thousand-triangle grid answers a local ray within a small BVH traversal allowance")
    func spatialTraversal() throws {
        var vertices: [Vector3] = [], faces: [UInt32] = []
        for z in 0...100 { for x in 0...100 { vertices.append([Float(x), 0, Float(z)]) } }
        for z in 0..<100 {
            for x in 0..<100 {
                let a = UInt32(z * 101 + x)
                faces.append(contentsOf: [a, a + 101, a + 1, a + 1, a + 101, a + 102])
            }
        }
        let index = try #require(try? TriangleSurfaceIndex(positions: vertices, indices: faces))
        let hit = try #require(try index.raycast(.init(origin: [50.17, 4, 50.31], direction: [0, -1, 0]), maximumWork: 256))
        #expect(abs(hit.position.y) < 1e-6 && abs(hit.distance - 4) < 1e-6)
    }

    @Test("A canceled query exits before traversing the committed immutable index")
    func cancellation() async throws {
        let index = try #require(try? TriangleSurfaceIndex(positions: positions, indices: indices))
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try index.raycast(.init(origin: [0, 6, 0], direction: [0, -1, 0]))
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
    }
}
