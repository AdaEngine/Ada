import AdaAssets
import Foundation

/// COW canonical channels; a page owns its integer samples independently of physical draw coverage.
struct TerrainSurfaceTileRows: Sendable {
    var id = UUID()
    var samples: [Int: TerrainRegionSurfaceSample] = [:]
    var masks: [UInt32: TerrainRegionRuleMaskSample] = [:]
    var coverage = TerrainSurfaceOverrideCoverage()

    mutating func insert(_ sample: TerrainRegionSurfaceSample, at index: Int) {
        samples[index] = sample
        if sample.tintStrength > 0 || sample.roughnessStrength > 0 { coverage.include(index) }
    }

    mutating func rebuildCoverage() {
        coverage = .init()
        for (index, sample) in samples where sample.tintStrength > 0 || sample.roughnessStrength > 0 { coverage.include(index) }
    }

    func hasSameValues(as other: Self) -> Bool { samples == other.samples && masks == other.masks }
}

struct TerrainSurfaceStorageRows: Sendable {
    // Conservative hash-table and COW staging allowance, distinct from the cache's decoded array charge.
    static let sampleCharge = MemoryLayout<TerrainRegionSurfaceSample>.stride * 4 + 64
    static let maskCharge = MemoryLayout<TerrainRegionRuleMaskSample>.stride * 4 + 64
    static let cellCharge = 1_024
    var cells: [TerrainTileCoordinate: TerrainSurfaceTileRows] = [:]
    var sampleCount = 0
    var maskCount = 0
    var budgetBytes = 32 * 1_024 * 1_024

    var chargedBytes: Int { sampleCount * Self.sampleCharge + maskCount * Self.maskCharge + cells.count * Self.cellCharge }

    mutating func insert(_ region: TerrainRegionAsset) throws {
        var newCells: Set<TerrainTileCoordinate> = []
        for sample in region.surface { newCells.insert(Self.cell(x: sample.x, z: sample.z, region: region)) }
        for sample in region.ruleMasks { newCells.insert(Self.cell(x: sample.x, z: sample.z, region: region)) }
        let additions = newCells.filter { cells[$0] == nil }.count
        let charge = region.surface.count * Self.sampleCharge + region.ruleMasks.count * Self.maskCharge + additions * Self.cellCharge
        guard charge <= budgetBytes - chargedBytes else { throw TerrainHeightStorage.StorageError.memoryBudgetExceeded }
        for sample in region.surface {
            let cell = Self.cell(x: sample.x, z: sample.z, region: region)
            cells[cell, default: .init()].insert(sample, at: Self.index(x: sample.x, z: sample.z))
        }
        for sample in region.ruleMasks {
            let cell = Self.cell(x: sample.x, z: sample.z, region: region)
            let key = UInt32(Self.index(x: sample.x, z: sample.z)) << 16 | UInt32(sample.maskID)
            cells[cell, default: .init()].masks[key] = sample
        }
        sampleCount += region.surface.count
        maskCount += region.ruleMasks.count
    }

    func counts(in region: TerrainRegionCoordinate) -> (surface: Int, masks: Int) {
        var surface = 0, masks = 0
        for z in 0..<4 {
            for x in 0..<4 {
                let rows = cells[.init(x: region.x * 4 + x, z: region.z * 4 + z)]
                surface += rows?.samples.count ?? 0
                masks += rows?.masks.count ?? 0
            }
        }
        return (surface, masks)
    }

    func records(in region: TerrainRegionCoordinate) -> (surface: [TerrainRegionSurfaceSample], masks: [TerrainRegionRuleMaskSample]) {
        var surface: [TerrainRegionSurfaceSample] = [], masks: [TerrainRegionRuleMaskSample] = []
        for z in 0..<4 {
            for x in 0..<4 {
                if let rows = cells[.init(x: region.x * 4 + x, z: region.z * 4 + z)] {
                    surface.append(contentsOf: rows.samples.values)
                    masks.append(contentsOf: rows.masks.values)
                }
            }
        }
        surface.sort { $0.z == $1.z ? $0.x < $1.x : $0.z < $1.z }
        masks.sort {
            if $0.z != $1.z {
                return $0.z < $1.z
            }
            if $0.x != $1.x {
                return $0.x < $1.x
            }
            return $0.maskID < $1.maskID
        }
        return (surface, masks)
    }

    mutating func prune(near region: TerrainRegionCoordinate, keeping predicate: (TerrainGridPoint) -> Bool) {
        for z in 0...4 {
            for x in 0...4 {
                let cell = TerrainTileCoordinate(x: region.x * 4 + x, z: region.z * 4 + z)
                guard var rows = cells[cell] else { continue }
                let oldSamples = rows.samples.count, oldMasks = rows.masks.count
                rows.samples = rows.samples.filter { predicate(Self.point(index: $0.key, cell: cell)) }
                rows.masks = rows.masks.filter { predicate(Self.point(index: Int($0.key >> 16), cell: cell)) }
                sampleCount -= oldSamples - rows.samples.count
                maskCount -= oldMasks - rows.masks.count
                guard oldSamples != rows.samples.count || oldMasks != rows.masks.count else { continue }
                if rows.samples.isEmpty && rows.masks.isEmpty { cells.removeValue(forKey: cell) } else {
                    if oldSamples != rows.samples.count { rows.rebuildCoverage() }
                    rows.id = UUID()
                    cells[cell] = rows
                }
            }
        }
    }

    func hasSurfaceOverrides(in tile: TerrainTileCoordinate, cellCountX: Int = 64, cellCountZ: Int = 64) -> Bool {
        surfaceOverrideCoverage(in: tile, cellCountX: cellCountX, cellCountZ: cellCountZ).painted
    }

    func surfaceOverrideCoverage(in tile: TerrainTileCoordinate, cellCountX: Int = 64, cellCountZ: Int = 64) -> (painted: Bool, rowVisits: Int) {
        let minimumX = tile.x * 64, minimumZ = tile.z * 64
        for z in tile.z...(tile.z + cellCountZ / 64) {
            for x in tile.x...(tile.x + cellCountX / 64) {
                let cell = TerrainTileCoordinate(x: x, z: z)
                guard let rows = cells[cell] else { continue }
                if rows.coverage.contains(
                    minimumX: max(0, minimumX - x * 64),
                    maximumX: min(63, minimumX + cellCountX - x * 64),
                    minimumZ: max(0, minimumZ - z * 64),
                    maximumZ: min(63, minimumZ + cellCountZ - z * 64)
                ) {
                    // Cached bit tests visit no authored sample records; the preflight diagnostic counts those records only.
                    return (true, 0)
                }
            }
        }
        return (false, 0)
    }

    func sample(at point: TerrainGridPoint) -> TerrainRegionSurfaceSample? {
        let address = Self.locate(point)
        return cells[address.cell]?.samples[address.index]
    }

    func mask(at point: TerrainGridPoint, id: UInt16) -> Float {
        let address = Self.locate(point)
        let key = UInt32(address.index) << 16 | UInt32(id)
        return cells[address.cell]?.masks[key]?.value ?? 0
    }

    static func locate(_ point: TerrainGridPoint) -> (cell: TerrainTileCoordinate, index: Int) {
        func floorDiv(_ value: Int) -> Int { value / 64 - (value % 64 < 0 ? 1 : 0) }
        let cell = TerrainTileCoordinate(x: floorDiv(point.x), z: floorDiv(point.z))
        return (cell, (point.z - cell.z * 64) * 64 + (point.x - cell.x * 64))
    }

    private static func cell(x: UInt8, z: UInt8, region: TerrainRegionAsset) -> TerrainTileCoordinate {
        .init(x: Int(region.x) * 4 + Int(x) / 64, z: Int(region.z) * 4 + Int(z) / 64)
    }

    private static func index(x: UInt8, z: UInt8) -> Int { Int(z % 64) * 64 + Int(x % 64) }

    private static func point(index: Int, cell: TerrainTileCoordinate) -> TerrainGridPoint {
        .init(x: cell.x * 64 + index % 64, z: cell.z * 64 + index / 64)
    }
}

/// Exact optional 64-by-64 coverage, created only for positive tint/roughness overrides.
/// Shared borders and partial tiles query bits without walking artist-authored records.
struct TerrainSurfaceOverrideCoverage: Sendable {
    private var rows: [UInt64] = []

    mutating func include(_ index: Int) {
        if rows.isEmpty { rows = [UInt64](repeating: 0, count: 64) }
        rows[index / 64] |= UInt64(1) << UInt64(index % 64)
    }

    func contains(minimumX: Int, maximumX: Int, minimumZ: Int, maximumZ: Int) -> Bool {
        guard !rows.isEmpty, minimumX <= maximumX, minimumZ <= maximumZ else {
            return false
        }
        if minimumX == 0, maximumX == 63, minimumZ == 0, maximumZ == 63 {
            return true
        }
        let mask = (UInt64.max << UInt64(minimumX)) & (UInt64.max >> UInt64(63 - maximumX))
        for z in minimumZ...maximumZ where rows[z] & mask != 0 {
            return true
        }
        return false
    }
}
