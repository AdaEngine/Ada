import Math
import Testing

@Suite("Triangle surface exact boundary classification")
struct TriangleSurfaceBoundaryTests {
    @Test("A representable point just outside a triangle edge remains outside for both ray and closest queries")
    func outsideEdge() throws {
        let index = try TriangleSurfaceIndex(positions: [.zero, [0, 0, 1], [1, 0, 0]], indices: [0, 1, 2])
        let outside: Float = -1e-13
        let hit = try index.raycast(.init(origin: [outside, 1, 0.25], direction: [0, -1, 0]))
        #expect(hit == nil, "A fixed containment tolerance must not expand the triangle beyond its actual edge")
        let closest = try #require(try index.closest(to: [outside, 0, 0.25]))
        #expect(closest.position.x == 0 && closest.distance > 0)
        let edge = try #require(try index.raycast(.init(origin: [0, 1, 0.25], direction: [0, -1, 0])))
        #expect(edge.position.x == 0 && edge.position.y == 0)
    }
}
