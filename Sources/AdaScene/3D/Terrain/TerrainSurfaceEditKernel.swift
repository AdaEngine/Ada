import AdaAssets
import Foundation

public enum TerrainSurfaceEditError: LocalizedError {
    case tooManyUpdates, duplicateSample, invalidCoordinate, missingSurface, invalidValue, materialPaletteRequired
    case missingLayer(UInt16)
    case surfaceBudgetExceeded, regionBudgetExceeded

    public var errorDescription: String? {
        switch self {
        case .tooManyUpdates: "Surface edit exceeds 65536 paint/mask updates"
        case .duplicateSample: "Surface edit contains duplicate paint points or mask identities"
        case .invalidCoordinate: "Surface edit lies outside the supported grid"
        case .missingSurface: "Surface editing requires a resident authored surface"
        case .invalidValue: "Surface channels must be finite, normalized and within their allowed ranges"
        case .materialPaletteRequired: "Layer painting requires a loaded material palette"
        case let .missingLayer(id): "Painted terrain layer \(id) is missing from the palette"
        case .surfaceBudgetExceeded: "Surface edit exceeds its canonical field memory budget"
        case .regionBudgetExceeded: "Surface edit exceeds the native region record budget"
        }
    }
}

/// Validates the whole gesture before copying changed COW dictionaries; no live state is mutated here.
struct TerrainSurfaceEditKernel {
    private struct MaskKey: Hashable { let point: TerrainGridPoint; let id: UInt16 }
    private struct Counts { var surface = 0; var masks = 0 }

    let storage: TerrainSurfaceStorageRows
    let surface: [TerrainSurfaceChange]
    let masks: [TerrainRuleMaskChange]
    let points: Set<TerrainGridPoint>

    init(
        surface updates: [TerrainSurfaceUpdate],
        masks maskUpdates: [TerrainRuleMaskUpdate],
        original: TerrainSurfaceStorageRows,
        layers: Set<UInt16>?,
        contains: (TerrainGridPoint) -> Bool
    ) throws {
        guard updates.count <= 65_536, maskUpdates.count <= 65_536 - updates.count else { throw TerrainSurfaceEditError.tooManyUpdates }
        var seen: Set<TerrainGridPoint> = [], maskKeys: Set<MaskKey> = [], points: Set<TerrainGridPoint> = []
        var surface: [TerrainSurfaceChange] = [], masks: [TerrainRuleMaskChange] = []
        var cellChanges: [TerrainTileCoordinate: Counts] = [:], regionChanges: [TerrainRegionCoordinate: Counts] = [:]
        func validate(_ point: TerrainGridPoint) throws {
            let limit = TerrainHeightStorage.gridLimit
            guard (-limit...limit).contains(point.x), (-limit...limit).contains(point.z) else { throw TerrainSurfaceEditError.invalidCoordinate }
            guard contains(point) else { throw TerrainSurfaceEditError.missingSurface }
        }
        for update in updates {
            try Task.checkCancellation()
            try validate(update.point)
            guard seen.insert(update.point).inserted else { throw TerrainSurfaceEditError.duplicateSample }
            if let paint = update.paint {
                do { try paint.validate() } catch { throw TerrainSurfaceEditError.invalidValue }
            }
            let paint = update.paint.flatMap { $0.isEmpty ? nil : $0 }
            if let paint, paint.overrideStrength > 0 {
                guard let layers else { throw TerrainSurfaceEditError.materialPaletteRequired }
                for channel in 0..<4 where paint.weights[channel] > 0 {
                    let id = paint.layerIDs[channel]
                    guard layers.contains(id) else { throw TerrainSurfaceEditError.missingLayer(id) }
                }
            }
            let previous = original.sample(at: update.point)?.paint
            guard previous != paint else { continue }
            surface.append(.init(point: update.point, previous: previous, paint: paint))
            points.insert(update.point)
            let change = (paint == nil ? 0 : 1) - (previous == nil ? 0 : 1)
            let cell = TerrainSurfaceStorageRows.locate(update.point).cell
            cellChanges[cell, default: .init()].surface += change
            regionChanges[TerrainInstanceEditKernel.region(cell), default: .init()].surface += change
        }
        for update in maskUpdates {
            try Task.checkCancellation()
            try validate(update.point)
            guard maskKeys.insert(.init(point: update.point, id: update.maskID)).inserted else { throw TerrainSurfaceEditError.duplicateSample }
            guard update.value.isFinite, (0...1).contains(update.value) else { throw TerrainSurfaceEditError.invalidValue }
            let previous = original.mask(at: update.point, id: update.maskID)
            guard previous != update.value else { continue }
            masks.append(.init(point: update.point, maskID: update.maskID, previousValue: previous, value: update.value))
            points.insert(update.point)
            let change = (update.value > 0 ? 1 : 0) - (previous > 0 ? 1 : 0)
            let cell = TerrainSurfaceStorageRows.locate(update.point).cell
            cellChanges[cell, default: .init()].masks += change
            regionChanges[TerrainInstanceEditKernel.region(cell), default: .init()].masks += change
        }
        var sampleCount = original.sampleCount, maskCount = original.maskCount, cellCount = original.cells.count
        for (cell, change) in cellChanges {
            let old = original.cells[cell]
            let samples = (old?.samples.count ?? 0) + change.surface, masks = (old?.masks.count ?? 0) + change.masks
            if old == nil && samples + masks > 0 { cellCount += 1 }
            if old != nil && samples + masks == 0 { cellCount -= 1 }
            sampleCount += change.surface; maskCount += change.masks
        }
        guard cellCount <= 65_536 else { throw TerrainSurfaceEditError.surfaceBudgetExceeded }
        let bytes = sampleCount * TerrainSurfaceStorageRows.sampleCharge + maskCount * TerrainSurfaceStorageRows.maskCharge
            + cellCount * TerrainSurfaceStorageRows.cellCharge
        guard bytes <= original.budgetBytes else { throw TerrainSurfaceEditError.surfaceBudgetExceeded }
        for (region, change) in regionChanges {
            let old = original.counts(in: region)
            guard old.surface + change.surface <= 65_536, old.masks + change.masks <= 262_144 else { throw TerrainSurfaceEditError.regionBudgetExceeded }
        }
        var result = original
        var changedPaintCells: Set<TerrainTileCoordinate> = []
        for change in surface {
            let address = TerrainSurfaceStorageRows.locate(change.point)
            changedPaintCells.insert(address.cell)
            if let paint = change.paint {
                let x = Self.local(change.point.x), z = Self.local(change.point.z)
                result.cells[address.cell, default: .init()].samples[address.index] = paint.regionSample(x: x, z: z)
            } else { result.cells[address.cell]?.samples.removeValue(forKey: address.index) }
        }
        for change in masks {
            let address = TerrainSurfaceStorageRows.locate(change.point)
            let key = UInt32(address.index) << 16 | UInt32(change.maskID)
            if change.value > 0 {
                result.cells[address.cell, default: .init()].masks[key] = .init(
                    x: Self.local(change.point.x), z: Self.local(change.point.z), maskID: change.maskID, value: change.value
                )
            } else { result.cells[address.cell]?.masks.removeValue(forKey: key) }
        }
        for cell in cellChanges.keys {
            guard var rows = result.cells[cell] else { continue }
            if rows.samples.isEmpty && rows.masks.isEmpty { result.cells.removeValue(forKey: cell) } else {
                if changedPaintCells.contains(cell) { rows.rebuildCoverage() }
                rows.id = UUID()
                result.cells[cell] = rows
            }
        }
        result.sampleCount = sampleCount; result.maskCount = maskCount
        surface.sort { $0.point.z == $1.point.z ? $0.point.x < $1.point.x : $0.point.z < $1.point.z }
        masks.sort {
            if $0.point.z != $1.point.z {
                return $0.point.z < $1.point.z
            }
            if $0.point.x != $1.point.x {
                return $0.point.x < $1.point.x
            }
            return $0.maskID < $1.maskID
        }
        storage = result; self.surface = surface; self.masks = masks; self.points = points
    }

    private static func local(_ value: Int) -> UInt8 {
        let remainder = value % 256
        return UInt8(remainder < 0 ? remainder + 256 : remainder)
    }
}
