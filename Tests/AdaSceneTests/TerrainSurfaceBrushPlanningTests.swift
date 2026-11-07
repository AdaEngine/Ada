import AdaAssets
@testable import AdaScene
import Math
import Testing

@Suite("Terrain surface brush planning")
struct TerrainSurfaceBrushPlanningTests {
    private func evaluate(_ storage: TerrainHeightStorage, settings: TerrainSurfaceBrushSettings, points: [TerrainBrushPoint]) throws
        -> (surface: [TerrainSurfaceUpdate], masks: [TerrainRuleMaskUpdate]) {
        let stroke = TerrainSurfaceBrushStroke(settings: settings, points: points)
        let plan = try TerrainHeightBrushPlan(source: storage, stroke: stroke.samplingStroke())
        let result = try TerrainSurfaceBrushKernel(source: storage, stroke: stroke, plan: plan).evaluate()
        return (result.surface, result.masks)
    }

    @Test("Surface spacing is independent of collinear event subdivision and event duration")
    func surfaceBrushSpacing() throws {
        let storage = try TerrainHeightStorage()
        try storage.allocateRegion(at: .init(x: 0, z: 0))
        var settings = TerrainSurfaceBrushSettings(operation: .paintMask, radius: 2, strength: 0.25)
        settings.spacing = 0.5; settings.rotationJitter = 0.5; settings.seed = 57; settings.maskID = 9
        let sparse: [TerrainBrushPoint] = [.init(position: [32, 0, 32], time: 0), .init(position: [40, 0, 32], time: 0.1)]
        let dense: [TerrainBrushPoint] = [
            .init(position: [32, 0, 32], time: 0), .init(position: [36, 0, 32], time: 4), .init(position: [40, 0, 32], time: 8),
        ]
        let first = try evaluate(storage, settings: settings, points: sparse)
        let second = try evaluate(storage, settings: settings, points: dense)
        #expect(!first.masks.isEmpty && first.surface.isEmpty)
        #expect(first.masks == second.masks)
        #expect(first.masks.allSatisfy { $0.value > 0 && $0.value <= 1 && $0.maskID == 9 })
    }

    @Test("Surface alpha, pressure and original height/slope filters bound the affected samples")
    func surfaceBrushMasks() throws {
        let storage = try TerrainHeightStorage()
        try storage.allocateRegion(at: .init(x: 0, z: 0))
        let revision = storage.revision
        let points: [TerrainBrushPoint] = [.init(position: [32, 0, 32], time: 0)]
        var settings = TerrainSurfaceBrushSettings(operation: .paintMask, radius: 2)
        settings.shape = .alpha(try .init(width: 1, height: 1, values: [0]))
        #expect(try evaluate(storage, settings: settings, points: points).masks.isEmpty)
        settings.shape = .alpha(try .init(width: 1, height: 1, values: [255]))
        settings.rotation = .pi / 4
        #expect(try !evaluate(storage, settings: settings, points: points).masks.isEmpty)
        settings.heightRange = 1...2
        #expect(try evaluate(storage, settings: settings, points: points).masks.isEmpty)
        settings.heightRange = nil; settings.slopeRange = 10...90
        #expect(try evaluate(storage, settings: settings, points: points).masks.isEmpty)
        settings.slopeRange = nil
        #expect(try evaluate(storage, settings: settings, points: [.init(position: [32, 0, 32], time: 0, pressure: 0)]).masks.isEmpty)
        #expect(storage.revision == revision && storage.residentSurfaceBytes == 0)
    }

    @Test("Layer brushes keep the strongest four stable IDs and full erase retains tint")
    func surfaceBrushLayerPruning() throws {
        let previous = TerrainSurfacePaint(
            layerIDs: [1, 2, 3, 4],
            weights: [0.25, 0.25, 0.25, 0.25],
            overrideStrength: 1,
            tint: [0.2, 0.3, 0.4, 1],
            tintStrength: 1
        )
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], surface: [previous.regionSample(x: 32, z: 32)])
        let storage = try TerrainHeightStorage(regions: [region])
        let points: [TerrainBrushPoint] = [.init(position: [32, 0, 32], time: 0)]
        var settings = TerrainSurfaceBrushSettings(operation: .paintLayer, radius: 0.75, strength: 0.5)
        settings.shape = .hardRound; settings.layerID = 5
        let result = try evaluate(storage, settings: settings, points: points)
        let paint = try #require(result.surface.first?.paint)
        #expect(result.surface.count == 1 && result.masks.isEmpty)
        #expect(paint.layerIDs == [5, 1, 2, 3] && abs(paint.weights.x - 4 / Float(7)) < 0.0001)
        #expect(abs(paint.weights.y - 1 / Float(7)) < 0.0001 && paint.tint == previous.tint && paint.tintStrength == 1)
        try paint.validate()
        settings.layerID = 2
        let repeated = try evaluate(storage, settings: settings, points: points)
        let sameLayer = try #require(repeated.surface.first?.paint)
        #expect(sameLayer.layerIDs.x == 2 && sameLayer.weights.x == 0.625)
        try sameLayer.validate()
        settings.operation = .eraseLayer; settings.strength = 1
        let erased = try evaluate(storage, settings: settings, points: points)
        let retainedTint = try #require(erased.surface.first?.paint)
        #expect(retainedTint.overrideStrength == 0 && retainedTint.weights == .zero && retainedTint.tint == previous.tint && retainedTint.tintStrength == 1)
        try retainedTint.validate()
    }

    @Test("Invalid and oversized surface brush plans fail before allocating authored records")
    func surfaceBrushBudgets() throws {
        let storage = try TerrainHeightStorage()
        try storage.allocateRegion(at: .init(x: 0, z: 0))
        let revision = storage.revision
        let points: [TerrainBrushPoint] = [.init(position: [32, 0, 32], time: 0)]
        var settings = TerrainSurfaceBrushSettings(operation: .paintMask, radius: 1_000_000)
        #expect(throws: TerrainHeightBrushError.self) { try evaluate(storage, settings: settings, points: points) }
        settings.radius = 2; settings.strength = 2
        #expect(throws: TerrainSurfaceEditError.self) { try evaluate(storage, settings: settings, points: points) }
        settings.strength = 1; settings.tint.x = .nan
        #expect(throws: TerrainSurfaceEditError.self) { try evaluate(storage, settings: settings, points: points) }
        #expect(storage.revision == revision && storage.residentSurfaceBytes == 0)
    }
}
