import AdaGeometry
import Foundation
import Math
import Testing

@Suite("Mesh Terrain paint projection")
struct MeshTerrainPaintProjectionTests {
    @Test("One painted sheet leaves a close ceiling and a disconnected parallel sheet untouched")
    func independentSheetsAndRecoverableMissingSection() async throws {
        let lower = try TriangleSurface.box(minimum: [-1, -0.1, -1], maximum: [1, 0, 1])
        let upper = try TriangleSurface.box(minimum: [-1, 0.1, -1], maximum: [1, 0.2, 1])
        let offset = UInt32(lower.positions.count)
        let surface = TriangleSurface(positions: lower.positions + upper.positions, indices: lower.indices + upper.indices.map { $0 + offset })
        let section = MeshTerrainBaseSection(surface: surface)
        var document = MeshTerrainDocument(sections: [section])
        let evaluator = MeshTerrainEvaluator()
        let before = try await evaluator.evaluate(document)
        let patch = try #require(before.patches.first)
        let hit = try #require(try patch.query.raycast(.init(origin: [0, 0.05, 0], direction: [0, -1, 0])))
        let anchor = try MeshTerrainSurfaceAnchor.capture(section: patch.id, surface: patch.surface, hit: hit, document: document)
        let stroke = MeshTerrainPaintStamp(anchor: anchor, radius: 4, strength: 1, operation: .paint(layer: 3))
        document.paint = [stroke]
        let baked = try MeshTerrainPaintBaker.bake(document: document, surface: before, budget: .init())
        let samples = try #require(baked.patches[section.id]?.samples)
        #expect(samples.count == 6)
        for sample in samples {
            let point = patch.surface.positions[Int(patch.surface.indices[sample.corner])]
            #expect(point.y == 0)
        }
        #expect(baked.orphans.isEmpty)

        document.sections = [.init(surface: surface)]
        let missing = try MeshTerrainPaintBaker.bake(document: document, surface: try await evaluator.evaluate(document), budget: .init())
        #expect(missing.patches.isEmpty)
        #expect(missing.orphans == [stroke.id])

        document.sections = [section]
        let restored = try MeshTerrainPaintBaker.bake(document: document, surface: try await evaluator.evaluate(document), budget: .init())
        #expect(restored.patches == baked.patches)
        #expect(restored.orphans.isEmpty)
    }
}
