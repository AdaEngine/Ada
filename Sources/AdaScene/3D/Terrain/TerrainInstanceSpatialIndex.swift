struct TerrainInstancePoint: Sendable {
    let x: Double
    let z: Double
}

struct TerrainInstanceSampleKey: Hashable, Sendable, Comparable {
    let x: Int64
    let z: Int64

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.z == rhs.z ? lhs.x < rhs.x : lhs.z < rhs.z }

    init(x: Int64, z: Int64) { self.x = x; self.z = z }

    init(point: TerrainInstancePoint, step: Double) throws {
        let x = (point.x / step).rounded(.down), z = (point.z / step).rounded(.down)
        guard x.isFinite, z.isFinite, abs(x) <= 4_503_599_627_370_496, abs(z) <= 4_503_599_627_370_496 else { throw TerrainInstanceBrushError.invalidCoordinates }
        self.x = Int64(x); self.z = Int64(z)
    }
}

/// A stroke-local exclusion grid; it never creates scene entities or scans every placement per candidate.
struct TerrainInstanceSpatialIndex {
    let distance: Double
    private var buckets: [TerrainInstanceSampleKey: [TerrainInstancePoint]] = [:]

    init(distance: Float) { self.distance = Double(distance) }

    mutating func insert(_ point: TerrainInstancePoint) throws {
        let key = try TerrainInstanceSampleKey(point: point, step: distance)
        buckets[key, default: []].append(point)
    }

    func containsNeighbor(_ point: TerrainInstancePoint, visits: inout Int) throws -> Bool {
        let key = try TerrainInstanceSampleKey(point: point, step: distance)
        for z: Int64 in -1...1 {
            for x: Int64 in -1...1 {
                for other in buckets[.init(x: key.x + x, z: key.z + z)] ?? [] {
                    visits += 1
                    guard visits <= TerrainInstanceBrushPlan.maximumVisits else { throw TerrainInstanceBrushError.workBudgetExceeded }
                    if visits % 256 == 0 { try Task.checkCancellation() }
                    let dx = point.x - other.x, dz = point.z - other.z
                    if dx * dx + dz * dz < distance * distance {
                        return true
                    }
                }
            }
        }
        return false
    }
}
