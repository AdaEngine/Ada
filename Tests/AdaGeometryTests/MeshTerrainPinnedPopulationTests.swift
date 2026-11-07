import AdaGeometry
import Math
import Testing

@Suite("Mesh Terrain pinned population")
struct MeshTerrainPinnedPopulationTests {
    @Test("A supported pin survives procedural clearing and reports when the attachment disappears")
    func pinsSurvivePopulationCoverageEdits() async throws {
        let floor = try TriangleSurface.ground(size: [12, 12], cells: 6)
        let section = MeshTerrainBaseSection(surface: floor, closure: .ground(bottomHeight: -4))
        let evaluator = MeshTerrainEvaluator()
        let original = MeshTerrainDocument(sections: [section])
        let surface = try await evaluator.evaluate(original)
        let bounds = MeshTerrainBounds(minimum: [-4, -1, -4], maximum: [4, 1, 4])
        let rule = MeshTerrainPopulationRule(prototypeID: 7, seed: 13, bounds: bounds)
        let generated = try MeshTerrainPopulation.evaluate([rule], surface: surface)
        var pin = try #require(generated.placements.first)
        pin.ownership = .pinned
        let edited = [MeshTerrainPopulationOverride(ruleID: rule.id, candidateID: pin.id, pinned: pin)]
        let cleared = try MeshTerrainPopulation.evaluate([rule], surface: surface,
            exclusions: [bounds.expanded(by: 2)], overrides: edited)
        #expect(cleared.placements == [pin])
        #expect(cleared.orphanedPins.isEmpty)

        var removed = original
        removed.sections[0].surface = try floor.transformed(by: .init(translation: [0, 8, 0]))
        let missing = try MeshTerrainPopulation.evaluate([rule], surface: try await evaluator.evaluate(removed), overrides: edited)
        #expect(missing.placements.isEmpty)
        #expect(missing.orphanedPins == [pin])
    }
}
