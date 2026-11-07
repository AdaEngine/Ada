import AdaGeometry
import Math
import Testing

@Suite("Surface-oriented Mesh Terrain sculpt")
struct MeshTerrainSurfaceSculptTests {
    @Test("Flatten follows the hit sheet and leaves a nearby opposite surface intact")
    func flattenOnlyHitSheet() async throws {
        let box = try TriangleSurface.box(minimum: [-2, -0.15, -2], maximum: [2, 0.15, 2])
        let brush = MeshTerrainSurfaceSculpt(center: [0, 0.15, 0], normal: .up, sourceID: 0,
            radius: 4, strength: 1, operation: .flatten(point: [0, 1, 0]))
        let section = MeshTerrainBaseSection(surface: box)
        let document = MeshTerrainDocument(sections: [section], modifiers: [
            .init(sourceID: 1, operation: .surfaceSculpt(brush), surface: .init(positions: [], indices: []))
        ])
        let result = try await MeshTerrainEvaluator().evaluate(document)
        let up = try #require(try result.raycast(.init(origin: [0, 4, 0], direction: [0, -1, 0]))?.hit)
        let down = try #require(try result.raycast(.init(origin: [0, -4, 0], direction: [0, 1, 0]))?.hit)
        #expect(up.position.y > 0.3)
        #expect(abs(down.position.y + 0.15) < 0.0001)
        #expect(result.patches.first?.surface.indices == box.indices)
    }

    @Test("Smooth reduces a spike using its actual triangle neighbors and preserves a ground seam")
    func smoothKeepsBoundaryContinuous() async throws {
        var left = try TriangleSurface.ground(size: [6, 6], cells: 6).transformed(by: .init(translation: [-3, 0, 0]))
        let right = try TriangleSurface.ground(size: [6, 6], cells: 6).transformed(by: .init(translation: [3, 0, 0]))
        let spike = try #require(left.positions.firstIndex(of: [-1, 0, 0]))
        left.positions[spike].y = 1
        let brush = MeshTerrainSurfaceSculpt(center: [-1, 1, 0], normal: .up, sourceID: 0,
            radius: 3, strength: 1, operation: .smooth)
        let document = MeshTerrainDocument(sections: [
            .init(surface: left, closure: .ground(bottomHeight: -4)),
            .init(surface: right, closure: .ground(bottomHeight: -4))
        ], modifiers: [.init(sourceID: 1, operation: .surfaceSculpt(brush), surface: .init(positions: [], indices: []))])
        let result = try await MeshTerrainEvaluator().evaluate(document)
        let height = try #require(try result.raycast(.init(origin: [-1, 4, 0], direction: [0, -1, 0]))?.hit.position.y)
        #expect((0..<0.9).contains(height))
        let first = try #require(result.patches.first)
        let last = try #require(result.patches.last)
        let seam = Set(first.surface.positions.filter { $0.x == 0 })
        #expect(seam.count == 7)
        #expect(seam == Set(last.surface.positions.filter { $0.x == 0 }))
    }
}
