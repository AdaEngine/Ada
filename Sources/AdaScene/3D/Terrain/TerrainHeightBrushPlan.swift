/// Geometry-independent bounded planning, shared by hydration and final brush evaluation.
struct TerrainHeightBrushPlan: Sendable {
    let dabs: [TerrainBrushDab]
    let footprint: Set<TerrainGridPoint>
    let reads: Set<TerrainGridPoint>

    init(source: TerrainHeightStorage, stroke: TerrainHeightBrushStroke) throws {
        let dabs = try stroke.sampledDabs()
        var footprint: Set<TerrainGridPoint> = []
        var visits = 0
        let factor = stroke.settings.operation == .talus ? stroke.settings.iterations * 8 : stroke.settings.operation == .smooth ? 10 : 2
        for dab in dabs where dab.pressure > 0 {
            try Task.checkCancellation()
            guard let bounds = TerrainBrushBounds(source: source, dab: dab, settings: stroke.settings) else { continue }
            guard bounds.area <= TerrainHeightBrushStroke.maximumVisits / factor,
                visits <= TerrainHeightBrushStroke.maximumVisits - bounds.area * factor
            else { throw TerrainHeightBrushError.workBudgetExceeded }
            visits += bounds.area * factor
            for z in bounds.minZ...bounds.maxZ {
                for x in bounds.minX...bounds.maxX {
                    let point = TerrainGridPoint(x: x, z: z)
                    if TerrainBrushMask.weight(point: point, source: source, dab: dab, settings: stroke.settings) != 0 { footprint.insert(point) }
                    guard footprint.count <= Terrain3DHeightEdit.maximumUpdates else { throw TerrainHeightBrushError.tooManySamples }
                }
            }
        }
        // Each dab scans the complete union and can copy its local value buffer. Count that
        // work and the canonical read halo before allocating/reading it, not only dab bounds.
        let activeDabs = dabs.reduce(0) { $0 + ($1.pressure > 0 ? 1 : 0) }
        let visitsPerPoint = 18 + activeDabs * factor
        guard footprint.count <= (TerrainHeightBrushStroke.maximumVisits - visits) / visitsPerPoint else {
            throw TerrainHeightBrushError.workBudgetExceeded
        }
        var reads: Set<TerrainGridPoint> = []
        for point in footprint {
            for z in -1...1 { for x in -1...1 { reads.insert(.init(x: point.x + x, z: point.z + z)) } }
        }
        self.dabs = dabs
        self.footprint = footprint
        self.reads = reads
    }
}
