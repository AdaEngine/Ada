@testable import AdaPlatform
@testable import AdaUI
import Math
import Testing

@MainActor
struct ClipContainmentTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test(arguments: [false, true])
    func roundedMaskPreservesInteriorAndClipsCorner(reverseWinding: Bool) throws {
        let tessellator = UITessellator()
        let path = RoundedRectangleShape(cornerRadius: 30).path(in: Rect(x: 0, y: 0, width: 100, height: 100))
        var polygon = try #require(tessellator.clipPathPolygons(path, transform: .identity).first)
        if reverseWinding { polygon.reverse() }
        let interior = tessellator.tessellateClippedQuad(
            transform: Rect(x: 40, y: 40, width: 20, height: 20).toTransform3D,
            texture: nil,
            color: .red,
            textureIndex: 0,
            clipPolygons: [polygon]
        )
        #expect(interior.vertices.count == 4)
        #expect(interior.indices.count == 6)
        #expect(interior.vertices.allSatisfy { $0.color == .red })

        let corner = tessellator.tessellateClippedQuad(
            transform: Rect(x: 0, y: 0, width: 20, height: 20).toTransform3D,
            texture: nil,
            color: .red,
            textureIndex: 0,
            clipPolygons: [polygon]
        )
        #expect(!corner.vertices.isEmpty)
        #expect(!corner.vertices.contains { $0.position.x == 0 && $0.position.y == 0 })
        #expect(corner.vertices.allSatisfy { $0.position.x >= -0.001 && $0.position.y <= 0.001 })
    }

    @Test
    func diamondAndMultipleMasksPreserveExistingCoverage() {
        let polygon = [Vector2(50, 0), Vector2(100, -50), Vector2(50, -100), Vector2(0, -50)]
        let tessellator = UITessellator()
        let inside = tessellator.tessellateClippedQuad(
            transform: Rect(x: 40, y: 40, width: 20, height: 20).toTransform3D,
            texture: nil,
            color: .blue,
            textureIndex: 0,
            clipPolygons: [polygon, polygon]
        )
        // Separate subpaths retain their coverage; containment must not merge them.
        #expect(inside.vertices.count == 8)
        #expect(inside.indices.count == 12)
        let crossing = tessellator.tessellateClippedQuad(
            transform: Rect(x: 10, y: 10, width: 80, height: 80).toTransform3D,
            texture: nil,
            color: .blue,
            textureIndex: 0,
            clipPolygons: [polygon]
        )
        #expect(crossing.vertices.count == 8)
        #expect(crossing.indices.count == 18)
    }
}
