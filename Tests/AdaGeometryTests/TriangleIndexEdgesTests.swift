import Math
import Testing

@Suite struct TriangleIndexEdgesTests {
    @Test func selectedCutUsesExactlyItsTriangles() throws {
        let edges = try #require(TriangleIndexEdges.make(from: [7, 2, 9, 9, 2, 3]))
        #expect(edges == [7, 2, 2, 9, 9, 7, 9, 2, 2, 3, 3, 9])
        try #require(edges.count == 12)
        #expect(Array(edges[6..<12]) == [9, 2, 2, 3, 3, 9])
        #expect(TriangleIndexEdges.make(from: [1, 2]) == nil)
        #expect(TriangleIndexEdges.make(from: [1, 2, 3], maximumIndices: 5) == nil)
    }
}
