import AdaAssets
import Foundation
import Math

public enum TerrainInstanceEditError: LocalizedError {
    case tooManyChanges, invalidCoordinate, staleCell, duplicateID, instanceBudgetExceeded, unloadedRegion

    public var errorDescription: String? {
        switch self {
        case .tooManyChanges: "Placement edit exceeds its bounded cell/record work budget"
        case .invalidCoordinate: "Placement edit contains duplicate cells or a record outside its addressed cell"
        case .staleCell: "Placement cell differs from the values captured by this edit"
        case .duplicateID: "Placement IDs must be unique across resident cells"
        case .instanceBudgetExceeded: "Placement edit exceeds its storage, cell or region-record budget"
        case .unloadedRegion: "Load the declared terrain region before editing its placement cells"
        }
    }
}

/// Preflights one explicit gesture over COW metadata; source rows remain immutable until publication.
struct TerrainInstanceEditKernel {
    let cells: [TerrainTileCoordinate: TerrainInstanceCellRows]
    let locations: [UInt64: TerrainTileCoordinate]
    let changes: [TerrainInstanceCellChange]
    let count: Int

    init(
        _ requested: [TerrainInstanceCellChange],
        cells original: [TerrainTileCoordinate: TerrainInstanceCellRows],
        locations originalLocations: [UInt64: TerrainTileCoordinate],
        count originalCount: Int,
        maximumCount: Int
    ) throws {
        if requested.isEmpty {
            self.cells = original; self.locations = originalLocations; self.changes = []; self.count = originalCount
            return
        }
        guard requested.count <= 65_536 else { throw TerrainInstanceEditError.tooManyChanges }
        var coordinates: Set<TerrainTileCoordinate> = []
        var regions: Set<TerrainRegionCoordinate> = []
        var visits = 0
        var changes: [TerrainInstanceCellChange] = []
        for change in requested {
            try Task.checkCancellation()
            guard change.previous.count <= 262_144 - visits else { throw TerrainInstanceEditError.tooManyChanges }
            visits += change.previous.count
            guard change.instances.count <= 262_144 - visits, change.instances.count <= 65_536 else { throw TerrainInstanceEditError.tooManyChanges }
            visits += change.instances.count
            let coordinate = change.coordinate
            let region = Self.region(coordinate)
            guard (-4_096...4_096).contains(region.x), (-4_096...4_096).contains(region.z), coordinates.insert(coordinate).inserted else { throw TerrainInstanceEditError.invalidCoordinate }
            guard (original[coordinate]?.records ?? []) == change.previous else { throw TerrainInstanceEditError.staleCell }
            for (index, record) in change.instances.enumerated() {
                if index % 1_024 == 0 { try Task.checkCancellation() }
                guard Int(record.localPosition.x) / 64 == coordinate.x - region.x * 4,
                    Int(record.localPosition.z) / 64 == coordinate.z - region.z * 4
                else { throw TerrainInstanceEditError.invalidCoordinate }
            }
            if change.previous != change.instances { changes.append(change); regions.insert(region) }
        }
        var count = originalCount
        for change in changes { count -= change.previous.count }
        for change in changes {
            guard change.instances.count <= maximumCount - count else { throw TerrainInstanceEditError.instanceBudgetExceeded }
            count += change.instances.count
        }
        var regionCounts: [TerrainRegionCoordinate: Int] = [:]
        for (coordinate, rows) in original {
            let region = Self.region(coordinate)
            if regions.contains(region) { regionCounts[region, default: 0] += rows.records.count }
        }
        for change in changes { regionCounts[Self.region(change.coordinate), default: 0] -= change.previous.count }
        for change in changes {
            let region = Self.region(change.coordinate)
            guard regionCounts[region, default: 0] <= 65_536 - change.instances.count else { throw TerrainInstanceEditError.instanceBudgetExceeded }
            regionCounts[region, default: 0] += change.instances.count
        }
        var cells = original
        var locations = originalLocations
        for change in changes { for record in change.previous { locations.removeValue(forKey: record.id) } }
        for change in changes {
            for (index, record) in change.instances.enumerated() {
                if index % 1_024 == 0 { try Task.checkCancellation() }
                guard locations.updateValue(change.coordinate, forKey: record.id) == nil else { throw TerrainInstanceEditError.duplicateID }
            }
            if change.instances.isEmpty { cells.removeValue(forKey: change.coordinate) } else { cells[change.coordinate] = .init(records: change.instances) }
        }
        guard cells.count <= 65_536 else { throw TerrainInstanceEditError.instanceBudgetExceeded }
        self.cells = cells
        self.locations = locations
        self.changes = changes
        self.count = count
    }

    static func region(_ cell: TerrainTileCoordinate) -> TerrainRegionCoordinate {
        func floorDiv(_ value: Int) -> Int { value / 4 - (value % 4 < 0 ? 1 : 0) }
        return .init(x: floorDiv(cell.x), z: floorDiv(cell.z))
    }
}

extension TerrainSourceResidency {
    /// An absent declared baseline is unknown, never an empty authored region.
    /// Storage keeps complete baselines across save-reader adoption, even for empty normal halos.
    func needsInstanceAdmission(_ changes: [TerrainInstanceCellChange]) throws -> Bool {
        guard !changes.isEmpty else {
            return false
        }
        guard changes.count <= 65_536 else { throw TerrainInstanceEditError.tooManyChanges }
        let declared = Set(cache.manifest.heightRegions.map { TerrainRegionCoordinate(x: Int($0.x), z: Int($0.z)) })
        let touched = Set(changes.map { TerrainInstanceEditKernel.region($0.coordinate) })
        var needsAdmission = false
        for coordinate in touched.sorted() {
            try Task.checkCancellation()
            guard (-4_096...4_096).contains(coordinate.x), (-4_096...4_096).contains(coordinate.z) else { throw TerrainInstanceEditError.invalidCoordinate }
            if knownRegions.contains(coordinate) { continue }
            guard !declared.contains(coordinate) else { throw TerrainInstanceEditError.unloadedRegion }
            needsAdmission = true
        }
        return needsAdmission
    }
}
