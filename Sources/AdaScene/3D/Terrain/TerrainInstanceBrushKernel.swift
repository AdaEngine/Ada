import AdaAssets
import Math

/// Stroke-local generation. Returned cell replacements enter the same atomic history/publication path as sculpting.
struct TerrainInstanceBrushKernel {
    let source: TerrainHeightStorage
    let stroke: TerrainInstanceBrushStroke
    let plan: TerrainInstanceBrushPlan
    var materials: TerrainMaterialPalette?

    func evaluate() throws -> [TerrainInstanceCellChange] {
        let settings = stroke.settings
        var materialFilter = try TerrainInstanceMaterialFilter.make(source: source, palette: materials, settings: settings)
        let cells = source.instanceCellSnapshot()
        var visits = 0
        var relevant: [TerrainTileCoordinate] = []
        let size = Double(source.spacing) * 64
        for cell in cells.keys.sorted() {
            for bounds in plan.readBounds {
                try visit(&visits)
                if bounds.intersects(minX: Double(cell.x) * size, minZ: Double(cell.z) * size, size: size) {
                    relevant.append(cell)
                    break
                }
            }
        }
        var replacements: [TerrainTileCoordinate: [TerrainRegionInstance]] = [:]
        if settings.operation == .erase {
            for cell in relevant {
                guard let rows = cells[cell]?.records else { continue }
                var kept: [TerrainRegionInstance] = []
                kept.reserveCapacity(rows.count)
                for row in rows {
                    try visit(&visits)
                    guard settings.eraseAllPrototypes || row.prototypeID == settings.prototypeID else { kept.append(row); continue }
                    let grid = gridPosition(row, in: cell)
                    let weight = try weight(at: grid, visits: &visits) * Double(settings.strength)
                    let threshold = TerrainInstanceBrushPlan.unit(row.id ^ settings.seed ^ 0xa076_1d64_78bd_642f)
                    if weight <= 0 || threshold >= min(1, weight) || !passesFilters(grid: grid) { kept.append(row); continue }
                    if try materialFilter?.accepts(grid: grid, visits: &visits) == false { kept.append(row) }
                }
                if kept != rows { replacements[cell] = kept }
            }
        } else {
            var index = TerrainInstanceSpatialIndex(distance: settings.minimumDistance)
            for cell in relevant {
                for row in cells[cell]?.records ?? [] {
                    try visit(&visits)
                    guard row.prototypeID == settings.prototypeID else { continue }
                    let grid = gridPosition(row, in: cell)
                    let point = TerrainInstancePoint(x: Double(grid.x) * Double(source.spacing), z: Double(grid.y) * Double(source.spacing))
                    if try containsReadBounds(point, visits: &visits) { try index.insert(point) }
                }
            }
            var accepted: Set<UInt64> = []
            // Grid indices identify a candidate only within this physical lattice scale.
            let latticeScale = (UInt64(settings.minimumDistance.bitPattern) << 32) | UInt64(source.spacing.bitPattern)
            let latticeSeed = settings.seed ^ TerrainInstanceBrushPlan.mix(latticeScale)
            for key in plan.candidates {
                try visit(&visits)
                let id = TerrainInstanceBrushPlan.hash(x: key.x, z: key.z, prototype: settings.prototypeID, seed: latticeSeed)
                guard !source.containsInstance(id: id), !accepted.contains(id) else { continue }
                let x = (Double(key.x) + 0.1 + 0.8 * TerrainInstanceBrushPlan.unit(id ^ 0xe703_7ed1_a0b4_28db)) * plan.step
                let z = (Double(key.z) + 0.1 + 0.8 * TerrainInstanceBrushPlan.unit(id ^ 0x8ebc_6af0_9c88_c6e3)) * plan.step
                let grid = Vector2(Float(x / Double(source.spacing)), Float(z / Double(source.spacing)))
                guard grid.x.isFinite, grid.y.isFinite, abs(grid.x) <= Float(TerrainHeightStorage.gridLimit), abs(grid.y) <= Float(TerrainHeightStorage.gridLimit) else { continue }
                let weight = try weight(at: grid, visits: &visits)
                let probability = min(1, Double(settings.density) * plan.step * plan.step) * Double(settings.strength) * weight
                guard TerrainInstanceBrushPlan.unit(id ^ 0x5899_65cc_7537_4cc3) < probability else { continue }
                let point = TerrainInstancePoint(x: Double(grid.x) * Double(source.spacing), z: Double(grid.y) * Double(source.spacing))
                guard try !index.containsNeighbor(point, visits: &visits), let sample = surface(grid: grid), passesFilters(height: sample.height, normal: sample.normal) else { continue }
                if try materialFilter?.accepts(grid: grid, visits: &visits) == false { continue }
                let cell = TerrainTileCoordinate(x: floorDiv(Int(grid.x.rounded(.down)), 64), z: floorDiv(Int(grid.y.rounded(.down)), 64))
                let region = TerrainInstanceEditKernel.region(cell)
                let scale = Float(
                    Double(settings.scaleRange.lowerBound) + Double(settings.scaleRange.upperBound - settings.scaleRange.lowerBound)
                        * TerrainInstanceBrushPlan.unit(id ^ 0x1d8e_4e27_c47d_124f)
                )
                let yaw = Float(
                    Double(settings.yawRange.lowerBound) + (Double(settings.yawRange.upperBound) - Double(settings.yawRange.lowerBound))
                        * TerrainInstanceBrushPlan.unit(id ^ 0xeb44_acca_b455_d165)
                )
                let turn = Quat(axis: [0, 1, 0], angle: yaw)
                let rotation = settings.alignToNormal ? TerrainHeightStorage.anchorMultiply(TerrainHeightStorage.anchorFrame(sample.normal), turn).normalized : turn
                var flags: TerrainInstanceFlags = settings.alignToNormal ? [.anchored, .alignToNormal] : [.anchored]
                if settings.requestsCollision { flags.insert(.collision) }
                let row = try TerrainRegionInstance(
                    id: id,
                    prototypeID: settings.prototypeID,
                    localPosition: [grid.x - Float(region.x * 256), Float((Double(sample.height) + Double(settings.heightOffset)) / Double(source.spacing)), grid.y - Float(region.z * 256)],
                    rotation: rotation,
                    scale: [scale, scale, scale],
                    tint: settings.tint,
                    seed: UInt32(truncatingIfNeeded: id),
                    flags: flags,
                    anchorNormal: sample.normal,
                    anchorOffset: settings.heightOffset / source.spacing
                )
                if replacements[cell] == nil { replacements[cell] = cells[cell]?.records ?? [] }
                replacements[cell, default: []].append(row)
                accepted.insert(id)
                try index.insert(point)
            }
        }
        return replacements.keys.sorted().compactMap { cell in
            guard let desired = replacements[cell], desired != (cells[cell]?.records ?? []) else {
                return nil
            }
            return .init(coordinate: cell, previous: cells[cell]?.records ?? [], instances: desired)
        }
    }

    private func containsReadBounds(_ point: TerrainInstancePoint, visits: inout Int) throws -> Bool {
        for bounds in plan.readBounds {
            try visit(&visits)
            if bounds.contains(point) {
                return true
            }
        }
        return false
    }

    private func gridPosition(_ row: TerrainRegionInstance, in cell: TerrainTileCoordinate) -> Vector2 {
        let region = TerrainInstanceEditKernel.region(cell)
        return Vector2(Float(region.x * 256) + row.localPosition.x, Float(region.z * 256) + row.localPosition.z)
    }

    private func weight(at grid: Vector2, visits: inout Int) throws -> Double {
        let position = source.origin + grid * source.spacing
        let point = TerrainGridPoint(x: Int(grid.x.rounded(.down)), z: Int(grid.y.rounded(.down)))
        var result = 0.0
        for dab in plan.dabs {
            try visit(&visits)
            result = max(result, TerrainBrushMask.weight(position: position, point: point, dab: dab, settings: plan.maskSettings) * Double(dab.pressure))
        }
        return max(0, min(1, result))
    }

    private func surface(grid: Vector2) -> (height: Float, normal: Vector3)? {
        guard let height = source.heightForAnchor(at: source.origin + grid * source.spacing) else {
            return nil
        }
        let x = Int(grid.x.rounded(.down)), z = Int(grid.y.rounded(.down))
        guard let normal = source.anchorNormal(x: x, z: z, fx: grid.x - Float(x), fz: grid.y - Float(z)) else {
            return nil
        }
        return (height, normal)
    }

    private func passesFilters(grid: Vector2) -> Bool {
        if stroke.settings.heightRange == nil && stroke.settings.slopeRange == nil {
            return true
        }
        guard let sample = surface(grid: grid) else {
            return false
        }
        return passesFilters(height: sample.height, normal: sample.normal)
    }

    private func passesFilters(height: Float, normal: Vector3) -> Bool {
        if let range = stroke.settings.heightRange, !range.contains(height) {
            return false
        }
        if let range = stroke.settings.slopeRange {
            let x = Double(normal.x), z = Double(normal.z)
            let angle = Float(Math.atan2((x * x + z * z).squareRoot(), Double(normal.y)) * 180 / Double.pi)
            if !range.contains(angle) {
                return false
            }
        }
        return true
    }

    private func visit(_ visits: inout Int) throws {
        visits += 1
        guard visits <= TerrainInstanceBrushPlan.maximumVisits else { throw TerrainInstanceBrushError.workBudgetExceeded }
        if visits % 256 == 0 { try Task.checkCancellation() }
    }

    private func floorDiv(_ value: Int, _ divisor: Int) -> Int { value / divisor - (value % divisor < 0 ? 1 : 0) }
}
