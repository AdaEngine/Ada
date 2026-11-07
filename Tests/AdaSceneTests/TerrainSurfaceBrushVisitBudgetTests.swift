@testable import AdaScene
import Testing

@Suite("Terrain surface brush visit budgets")
struct TerrainSurfaceBrushVisitBudgetTests {
    @Test("Inactive pointer travel cannot multiply admitted surface mask work", arguments: [true, false])
    func terrainSurfaceBrushVisitBudget(activeFirst: Bool) throws {
        let storage = try TerrainHeightStorage()
        try storage.allocateRegion(at: .init(x: 0, z: 0))
        var settings = TerrainSurfaceBrushSettings(operation: .paintMask, radius: 32)
        settings.shape = .hardRound; settings.spacing = 0.25
        let stroke = TerrainSurfaceBrushStroke(settings: settings, points: [
            .init(position: [64, 0, 64], time: 0, pressure: activeFirst ? 1 : 0),
            .init(position: [65, 0, 64], time: 1, pressure: 0),
            .init(position: [32_800, 0, 64], time: 2, pressure: 0),
        ])
        let plan = try TerrainHeightBrushPlan(source: storage, stroke: stroke.samplingStroke())
        try #require(plan.dabs.count >= 4_090 && plan.dabs.filter { $0.pressure > 0 }.count == (activeFirst ? 1 : 0))
        let result = try TerrainSurfaceBrushKernel(source: storage, stroke: stroke, plan: plan).evaluate()
        #expect(result.maskEvaluations <= TerrainHeightBrushStroke.maximumVisits)
        #expect(result.maskEvaluations == plan.footprint.count)
        #expect(result.masks.count == plan.footprint.count && result.surface.isEmpty)
        #expect(storage.residentSurfaceBytes == 0)
    }
}
