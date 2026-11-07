import AdaGeometry
import Foundation

extension MeshTerrainDocumentAsset {
    private struct AuthoringInput: Encodable {
        let algorithm = "AdaMeshTerrain.compiled.v1.manifold3.5.1"
        let document: MeshTerrainDocument
        let rules: [MeshTerrainPopulationRule]
        let manual: [MeshTerrainPlacement]
        let overrides: [MeshTerrainPopulationOverride]
    }

    /// Geometry and population inputs share one accepted generation.
    public func authoringKey() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return MeshTerrainContentKey.digest(try encoder.encode(AuthoringInput(document: document, rules: populationRules,
                                                                             manual: manualPlacements, overrides: populationOverrides)))
    }

    /// Builds an immutable player resource. Failures leave this authoring value
    /// and any previously accepted compiled product unchanged.
    @concurrent
    public func compiling(using evaluator: MeshTerrainEvaluator = .init(), budget: TriangleGeometryBudget = .init()) async throws -> Self {
        let key = try authoringKey()
        let snapshot = try await evaluator.evaluate(document, budget: budget)
        let population = try await evaluator.evaluatePopulation(
            populationRules, surface: snapshot, document: document, manual: manualPlacements, overrides: populationOverrides
        )
        let paint = try MeshTerrainPaintBaker.bake(document: document, surface: snapshot, budget: budget)
        try Task.checkCancellation()
        let product = MeshTerrainCompiledProduct(
            inputKey: key, patches: snapshot.patches.map { .init(id: $0.id, surface: $0.surface, paint: paint.patches[$0.id]) },
            placements: population.placements, paintOrphans: paint.orphans.isEmpty ? nil : paint.orphans,
            orphanedPins: population.orphanedPins.isEmpty ? nil : population.orphanedPins
        )
        let result = Self(document: document, populationRules: populationRules, manualPlacements: manualPlacements,
                          populationOverrides: populationOverrides, compiled: product)
        try result.validate()
        return result
    }

    public func acceptedCompiledProduct() throws -> MeshTerrainCompiledProduct {
        guard let compiled else { throw TriangleGeometryError.invalidInput }
        try validate()
        guard compiled.inputKey == (try authoringKey()), Set(compiled.patches.map(\.id)) == Set(document.sections.map(\.id)) else {
            throw TriangleGeometryError.invalidInput
        }
        return compiled
    }
}
