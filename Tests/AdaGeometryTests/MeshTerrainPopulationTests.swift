import AdaGeometry
import Foundation
import Math
import Testing

@Suite("Mesh terrain surface population")
struct MeshTerrainPopulationTests {
    private func ground() async throws -> MeshTerrainSurfaceSnapshot {
        try await MeshTerrainEvaluator().evaluate(.init(sections: [.init(surface: .ground(size: [12, 12], cells: 4), closure: .ground(bottomHeight: -8))]))
    }

    @Test("Moving an exclusion refills old ground deterministically and retains manual intent")
    func exclusionMovement() async throws {
        let surface = try await ground()
        let rule = MeshTerrainPopulationRule(prototypeID: 1, seed: 42, bounds: .init(minimum: [-5, -1, -5], maximum: [5, 1, 5]))
        let manual = MeshTerrainPlacement(id: 100, prototypeID: 2, transform: .init(translation: [-2, 0, 0]))
        let all = try MeshTerrainPopulation.evaluate([rule], surface: surface, manual: [manual])
        let old = MeshTerrainBounds(minimum: [-3, -1, -3], maximum: [0, 1, 3])
        let new = MeshTerrainBounds(minimum: [1, -1, -3], maximum: [4, 1, 3])
        let first = try MeshTerrainPopulation.evaluate([rule], surface: surface, exclusions: [old], manual: [manual])
        let moved = try MeshTerrainPopulation.evaluate([rule], surface: surface, exclusions: [new], manual: [manual])
        #expect(first.placements.contains(manual))
        #expect(moved.placements.contains(manual))
        let refill = Set(all.placements.filter { old.contains($0.transform.w.xyz) && $0.ownership == .generated }.map(\.id))
        #expect(!refill.isEmpty)
        #expect(refill.isSubset(of: Set(moved.placements.map(\.id))))
        #expect(refill.isDisjoint(with: Set(first.placements.map(\.id))))
        #expect(try MeshTerrainPopulation.evaluate([rule], surface: surface, exclusions: [old], manual: [manual]).placements == first.placements)
    }

    @Test("Joined sources regenerate precise environment clearance at both old and new locations", .enabled(if: TriangleMeshBoolean.isAvailable))
    func joinedSourceMovement() async throws {
        let ground = try TriangleSurface.ground(size: [12, 12], cells: 6)
        let source = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        let evaluator = MeshTerrainEvaluator()
        var document = MeshTerrainDocument(sections: [.init(surface: ground, closure: .ground(bottomHeight: -4))])
        let base = try await evaluator.evaluate(document)
        let rule = MeshTerrainPopulationRule(prototypeID: 1, seed: 73, bounds: .init(minimum: [-5, -0.1, -5], maximum: [5, 0.1, 5]),
            density: 2, spacing: 0.4, sourceExclusionDistance: 0.8)
        let manual = MeshTerrainPlacement(id: 123, prototypeID: 2, transform: .init(translation: [-2, 0, 0]))
        let all = try MeshTerrainPopulation.evaluate([rule], surface: base, manual: [manual])
        document.modifiers = [.init(sourceID: 7, operation: .union, surface: source, transform: .init(translation: [-2, 0, 0]))]
        let firstSurface = try await evaluator.evaluate(document)
        let first = try MeshTerrainPopulation.evaluate([rule], surface: firstSurface, manual: [manual])
        let oldSolid = try ScalarMeshSolid(positions: source.positions, indices: source.indices, transform: .init(translation: [-2, 0, 0]))
        let oldDistances = try first.placements.filter { $0.ownership == .generated }.map { try oldSolid.value(at: $0.transform.origin) }
        #expect(oldDistances.allSatisfy { $0 > 0.8 })
        document.modifiers[0].transform = .init(translation: [2, 0, 0])
        let movedSurface = try await evaluator.evaluate(document)
        let moved = try MeshTerrainPopulation.evaluate([rule], surface: movedSurface, manual: [manual])
        let newSolid = try ScalarMeshSolid(positions: source.positions, indices: source.indices, transform: .init(translation: [2, 0, 0]))
        let newDistances = try moved.placements.filter { $0.ownership == .generated }.map { try newSolid.value(at: $0.transform.origin) }
        #expect(newDistances.allSatisfy { $0 > 0.8 })
        let oldCandidates = try all.placements.filter { placement in
            guard placement.ownership == .generated else { return false }
            return try oldSolid.value(at: placement.transform.origin) <= 0.8
        }.map(\.id)
        #expect(!oldCandidates.isEmpty)
        #expect(Set(oldCandidates).isSubset(of: Set(moved.placements.map(\.id))))
        #expect(moved.placements.contains(manual))
        #expect(first.placements.contains(manual))
        #expect(try MeshTerrainPopulation.evaluate([rule], surface: movedSurface, manual: [manual]).placements == moved.placements)
    }

    @Test("Moving a root within one rebuilt section only resamples nearby population cells", .enabled(if: TriangleMeshBoolean.isAvailable))
    func localizedRootMovement() async throws {
        let ground = try TriangleSurface.ground(size: [64, 64], cells: 32)
        let root = try TriangleSurface.box(minimum: [-1, -1, -1], maximum: [1, 2, 1])
        let evaluator = MeshTerrainEvaluator()
        var document = MeshTerrainDocument(sections: [.init(surface: ground, closure: .ground(bottomHeight: -6))],
            modifiers: [.init(sourceID: 7, operation: .union, surface: root, transform: .init(translation: [-8, 0, 0]))])
        let rule = MeshTerrainPopulationRule(
            id: try #require(UUID(uuidString: "FE42A78C-5489-41B5-BDD8-9294A308933B")), prototypeID: 1, seed: 73,
            bounds: .init(minimum: [-29, -0.2, -29], maximum: [29, 0.2, 29]), density: 2, spacing: 0.6, cellSize: 8, sourceExclusionDistance: 1
        )
        let oldSurface = try await evaluator.evaluate(document)
        let old = try await evaluator.evaluatePopulation([rule], surface: oldSurface, document: document)
        document.modifiers[0].transform = .init(translation: [8, 0, 0])
        let surface = try await evaluator.evaluate(document)
        #expect(surface.rebuiltPatchCount == 1)
        let moved = try await evaluator.evaluatePopulation([rule], surface: surface, document: document)
        let cold = try MeshTerrainPopulation.evaluate([rule], surface: surface, document: document)
        #expect(moved.placements == cold.placements)
        #expect(moved.visitedCandidates > 0)
        #expect(moved.visitedCandidates < cold.visitedCandidates / 3)
        let far: (MeshTerrainPlacement) -> Bool = { abs($0.transform.origin.z) > 16 }
        #expect(!old.placements.filter(far).isEmpty)
        #expect(old.placements.filter(far) == moved.placements.filter(far))
        let oldIDs = Set(old.placements.map(\.id)), newIDs = Set(moved.placements.map(\.id))
        #expect(moved.placements.contains { !oldIDs.contains($0.id) && ($0.transform.origin - Vector3(-8, 0, 0)).length < 2 })
        #expect(old.placements.contains { !newIDs.contains($0.id) && ($0.transform.origin - Vector3(8, 0, 0)).length < 2 })
    }

    @Test("Suppressed candidates stay absent and pins remain authored overrides")
    func overrides() async throws {
        let surface = try await ground()
        let rule = MeshTerrainPopulationRule(prototypeID: 1, bounds: .init(minimum: [-4, -1, -4], maximum: [4, 1, 4]))
        let initial = try MeshTerrainPopulation.evaluate([rule], surface: surface)
        let first = try #require(initial.placements.first)
        let edited = MeshTerrainPlacement(id: first.id, ruleID: rule.id, prototypeID: 2, transform: first.transform, ownership: .pinned)
        let pinned = try MeshTerrainPopulation.evaluate([rule], surface: surface, overrides: [.init(ruleID: rule.id, candidateID: first.id, pinned: edited)])
        #expect(pinned.placements.contains(edited))
        let hidden = try MeshTerrainPopulation.evaluate([rule], surface: surface, overrides: [.init(ruleID: rule.id, candidateID: first.id, suppressed: true)])
        #expect(!hidden.placements.contains { $0.id == first.id })
    }
}
