@testable import AdaScene
import Math
import Testing

@Suite("Cross-tile surface nearest ordering")
struct TerrainSurfaceQueryOrderingTests {
    @Test("Ray and closest queries compare unrounded distances when distinct surfaces have the same Float distance")
    func closeSurfacesAtDistance() throws {
        func plane(_ x: Float) throws -> TerrainPreparedQuery {
            let index = try TriangleSurfaceIndex(positions: [[x, -1, -1], [x, 1, -1], [x, 0, 1]], indices: [0, 1, 2])
            return .init(index: index, chargedBytes: index.chargedBytes)
        }
        let queries = TerrainSurfaceQueries(revision: 1, queries: [.init(x: -1, z: 0): try plane(-1e-6), .init(x: 0, z: 0): try plane(1e-6)])
        let ray = try #require(try queries.raycast(.init(origin: [1_000, 0, 0], direction: [-1, 0, 0])))
        #expect(ray.position.x > 0 && ray.coordinate.x == 0, "Tile iteration order must not win over a nearer distinguishable position")
        let closest = try #require(try queries.closest(to: [1_000, 0, 0]))
        #expect(closest.position.x > 0 && closest.coordinate.x == 0)
        #expect(ray.distance == 1_000 && closest.distance == 1_000, "The fixture must exercise equal rounded public distances")
    }
}
