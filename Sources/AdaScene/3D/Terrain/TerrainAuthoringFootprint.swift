import Math

/// Read coverage for one gesture, before any candidate samples or live resources are changed.
struct TerrainAuthoringFootprint: Sendable {
    let brushPlan: TerrainHeightBrushPlan?
    let instancePlan: TerrainInstanceBrushPlan?
    let surfacePlan: TerrainHeightBrushPlan?
    let regions: Set<TerrainRegionCoordinate>

    init(edit: Terrain3DEdit, storage: TerrainHeightStorage, residency: TerrainSourceResidency?, maximumRegions: Int) throws {
        let plan: TerrainHeightBrushPlan?
        if let brush = edit.brush { plan = try .init(source: storage, stroke: brush) } else { plan = nil }
        guard edit.updates.count <= Terrain3DEdit.maximumUpdates else { throw TerrainHeightEditError.tooManyUpdates }
        var reads = plan?.reads ?? []
        let surfacePlan: TerrainHeightBrushPlan?
        if let brush = edit.surfaceBrush { surfacePlan = try .init(source: storage, stroke: brush.samplingStroke()) } else { surfacePlan = nil }
        if let surfacePlan { reads.formUnion(surfacePlan.reads) }
        for (index, update) in edit.updates.enumerated() {
            if index % 1_024 == 0 { try Task.checkCancellation() }
            guard (-TerrainHeightStorage.gridLimit...TerrainHeightStorage.gridLimit).contains(update.point.x),
                (-TerrainHeightStorage.gridLimit...TerrainHeightStorage.gridLimit).contains(update.point.z)
            else { throw TerrainHeightEditError.invalidCoordinate }
            guard update.height.isFinite else { throw TerrainHeightEditError.invalidHeight }
            for z in -1...1 { for x in -1...1 { reads.insert(.init(x: update.point.x + x, z: update.point.z + z)) } }
        }
        guard edit.surfaceUpdates.count <= 65_536, edit.maskUpdates.count <= 65_536 - edit.surfaceUpdates.count else {
            throw TerrainSurfaceEditError.tooManyUpdates
        }
        for point in edit.surfaceUpdates.map(\.point) + edit.maskUpdates.map(\.point) {
            guard (-TerrainHeightStorage.gridLimit...TerrainHeightStorage.gridLimit).contains(point.x),
                (-TerrainHeightStorage.gridLimit...TerrainHeightStorage.gridLimit).contains(point.z)
            else { throw TerrainSurfaceEditError.invalidCoordinate }
            // Canonical boundary ownership and its adjacent authored coverage must both be available.
            for z in -1...1 { for x in -1...1 { reads.insert(.init(x: point.x + x, z: point.z + z)) } }
        }
        if let first = edit.brush?.points.first {
            let x = (Double(first.position.x) - Double(storage.origin.x)) / Double(storage.spacing)
            let z = (Double(first.position.z) - Double(storage.origin.y)) / Double(storage.spacing)
            if x.isFinite, z.isFinite, abs(x) <= Double(TerrainHeightStorage.gridLimit), abs(z) <= Double(TerrainHeightStorage.gridLimit) {
                let point = TerrainGridPoint(x: Int(x.rounded(.down)), z: Int(z.rounded(.down)))
                for dz in -1...1 { for dx in -1...1 { reads.insert(.init(x: point.x + dx, z: point.z + dz)) } }
            }
        }
        var wanted: Set<TerrainRegionCoordinate> = []
        for (index, point) in reads.enumerated() {
            if index % 1_024 == 0 { try Task.checkCancellation() }
            wanted.insert(.init(x: Self.floorDiv(point.x, 256), z: Self.floorDiv(point.z, 256)))
        }
        guard edit.instanceChanges.count <= 65_536 else { throw TerrainInstanceEditError.tooManyChanges }
        for change in edit.instanceChanges {
            let region = TerrainInstanceEditKernel.region(change.coordinate)
            guard (-4_096...4_096).contains(region.x), (-4_096...4_096).contains(region.z) else { throw TerrainInstanceEditError.invalidCoordinate }
            wanted.insert(region)
        }
        let declared = residency.map { Set($0.cache.manifest.heightRegions.map { TerrainRegionCoordinate(x: Int($0.x), z: Int($0.z)) }) } ?? []
        let available = declared.union(residency?.knownRegions ?? []).union(storage.regionCoordinates)
        let instancePlan: TerrainInstanceBrushPlan?
        if let brush = edit.instanceBrush { instancePlan = try .init(source: storage, stroke: brush) } else { instancePlan = nil }
        var regions = wanted.intersection(available)
        if let instancePlan { regions.formUnion(try instancePlan.regions(source: storage, allowed: available, maximum: maximumRegions)) }
        guard regions.count <= maximumRegions else { throw TerrainRegionCache.CacheError.regionBudgetExceeded }
        self.brushPlan = plan
        self.instancePlan = instancePlan
        self.surfacePlan = surfacePlan
        self.regions = regions
    }

    private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        value / divisor - (value % divisor < 0 ? 1 : 0)
    }
}
