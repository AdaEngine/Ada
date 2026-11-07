import Foundation
import Math

extension MeshTerrainPopulation.CellPass {
    private struct Candidate {
        let placement: MeshTerrainPlacement
        let priority: UInt64
        let point: Vector3
        let sheet: UInt64
    }

    private struct Sample {
        let rule: MeshTerrainPopulationRule
        let patches: [MeshTerrainPopulation.IndexedPatch]
        let influences: [MeshTerrainPopulation.Influence]
        let coverage: MeshTerrainResolvedCoverage?
        let exclusions: [MeshTerrainBounds]
        let halo: MeshTerrainBounds
        let step: Float
    }

    mutating func sampleCell(
        _ coordinate: SIMD3<Int32>, core: MeshTerrainBounds, halo: MeshTerrainBounds, rule: MeshTerrainPopulationRule,
        patches: [MeshTerrainPopulation.IndexedPatch], influences: [MeshTerrainPopulation.Influence], coverage: MeshTerrainResolvedCoverage?,
        exclusions: [MeshTerrainBounds]
    ) throws -> [MeshTerrainPlacement] {
        let step = max(rule.spacing * 0.75, 1 / max(1, rule.density).squareRoot())
        let input = Sample(rule: rule, patches: patches, influences: influences, coverage: coverage, exclusions: exclusions, halo: halo, step: step)
        let low = (0..<3).map { Int(floor(halo.minimum[$0] / step)) }
        let high = (0..<3).map { Int(ceil(halo.maximum[$0] / step)) }
        let seed = Self.hash(rule.id.uuidString.utf8.reduce(UInt64(0)) { $0 &* 131 &+ UInt64($1) } ^ rule.seed)
        var candidates: [Candidate] = []
        for axis in 0..<3 {
            let u = (axis + 1) % 3, v = (axis + 2) % 3
            for first in low[u]...high[u] {
                for second in low[v]...high[v] {
                    try queryBudget.charge()
                    let firstKey = Self.hash(UInt64(bitPattern: Int64(first)) &+ 0x9E3779B97F4A7C15)
                    let secondKey = Self.hash(UInt64(bitPattern: Int64(second)) &+ 0xD1B54A32D192ED03)
                    let lattice = Self.hash(firstKey ^ secondKey &* 0x94D049BB133111EB ^ Self.hash(UInt64(axis) ^ seed))
                    var origin = Vector3.zero
                    origin[axis] = halo.maximum[axis].nextUp
                    origin[u] = (Float(first) + Float(lattice & 0xFFFF) / 65_536) * step
                    origin[v] = (Float(second) + Float((lattice >> 16) & 0xFFFF) / 65_536) * step
                    guard (halo.minimum[u]...halo.maximum[u]).contains(origin[u]), (halo.minimum[v]...halo.maximum[v]).contains(origin[v]) else { continue }
                    visitedCandidates += 1
                    guard visitedCandidates <= maximumCandidates else { throw TriangleGeometryError.budgetExceeded }
                    try collect(from: origin, axis: axis, lattice: lattice, input: input, into: &candidates)
                }
            }
        }
        return try admit(candidates, ownedBy: coordinate, core: core, rule: rule)
    }

    private mutating func collect(
        from origin: Vector3, axis: Int, lattice: UInt64, input: Sample, into candidates: inout [Candidate]
    ) throws {
        var origin = origin, direction = Vector3.zero
        direction[axis] = -1
        let lower = input.halo.minimum[axis].nextDown
        for _ in 0..<16 {
            let distance = (origin[axis] - lower).nextUp
            guard distance > 0, let found = try hit(.init(origin: origin, direction: direction), distance: distance, patches: input.patches) else { break }
            let point = found.hit.position
            // Advance by a representable coordinate, including at zero and large coordinates.
            origin[axis] = min(point[axis].nextDown, origin[axis].nextDown)
            if let candidate = try makeCandidate(found.hit, patch: found.patch, input: input, axis: axis, lattice: lattice) {
                candidates.append(candidate)
                guard candidates.count <= maximumCandidates else { throw TriangleGeometryError.budgetExceeded }
            }
        }
    }

    private mutating func makeCandidate(
        _ hit: TriangleSurfaceHit, patch: MeshTerrainPatch, input: Sample, axis: Int, lattice: UInt64
    ) throws -> Candidate? {
        let point = hit.position, normal = hit.normal, rule = input.rule
        let largest = max(abs(normal.x), max(abs(normal.y), abs(normal.z)))
        let dominant = abs(normal.x) >= abs(normal.y) && abs(normal.x) >= abs(normal.z) ? 0 : abs(normal.y) >= abs(normal.z) ? 1 : 2
        guard axis == dominant, rule.minimumUpDot <= normal.y, normal.y <= rule.maximumUpDot, input.halo.contains(point),
            !input.exclusions.contains(where: { $0.contains(point) }) else { return nil }
        let source = patch.surface.faceSources.isEmpty ? 0 : patch.surface.faceSources[hit.triangleIndex]
        let coverageWeight = try input.coverage?.density(at: point, normal: normal, source: source, patch: patch.id, budget: &queryBudget) ?? 1
        let ignoredSource = input.coverage == nil || source == 0 ? nil : source
        guard coverageWeight > 0,
            try !excluded(point, clearance: rule.sourceExclusionDistance, sources: input.influences, ignoring: ignoredSource) else { return nil }
        let side = UInt64(normal[axis] < 0 ? 1 : 0)
        let stratum = UInt64(bitPattern: Int64(floor(point[axis] / input.step)))
        let id = Self.hash(lattice ^ stratum &* 0x94D049BB133111EB ^ UInt64(source) ^ side << 48)
        let probability = min(1, rule.density * coverageWeight * input.step * input.step / max(0.5, largest))
        guard Float(id & 0xFFFFFF) / Float(0x1000000) < probability else { return nil }
        let scale = rule.minimumScale + (rule.maximumScale - rule.minimumScale) * Float((id >> 24) & 0xFFFF) / 65_535
        let yaw = Float((id >> 40) & 0xFFFF) / 65_535 * Float.pi * 2
        let rotation = Self.compose(Self.align(normal), Quat(axis: .up, angle: yaw))
        let placement = MeshTerrainPlacement(id: id, ruleID: rule.id, prototypeID: rule.prototypeID,
            transform: .init(translation: point + normal * rule.offset, rotation: rotation, scale: Vector3(scale)),
            ownership: .generated, patchID: patch.id, normal: normal, sourceID: source)
        return .init(placement: placement, priority: Self.hash(id), point: point, sheet: UInt64(source) << 3 | UInt64(axis) << 1 | side)
    }

    private mutating func admit(
        _ candidates: [Candidate], ownedBy coordinate: SIMD3<Int32>, core: MeshTerrainBounds, rule: MeshTerrainPopulationRule
    ) throws -> [MeshTerrainPlacement] {
        var neighbors: [SIMD3<Int32>: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() {
            neighbors[Self.coordinate(candidate.point, size: rule.spacing), default: []].append(index)
        }
        var admitted: [MeshTerrainPlacement] = []
        for candidate in candidates where core.contains(candidate.point) && Self.coordinate(candidate.point, size: rule.cellSize) == coordinate {
            let own = Self.coordinate(candidate.point, size: rule.spacing)
            if try !blocked(candidate, cell: own, by: neighbors, in: candidates, spacing: rule.spacing) {
                admitted.append(candidate.placement)
            }
        }
        return admitted
    }

    private mutating func blocked(
        _ candidate: Candidate, cell: SIMD3<Int32>, by neighbors: [SIMD3<Int32>: [Int]], in candidates: [Candidate], spacing: Float
    ) throws -> Bool {
        for z: Int32 in -1...1 {
            for y: Int32 in -1...1 {
                for x: Int32 in -1...1 {
                    for index in neighbors[cell &+ SIMD3(x, y, z)] ?? [] {
                        try queryBudget.charge()
                        neighborVisits += 1
                        guard neighborVisits <= maximumCandidates * 256 else { throw TriangleGeometryError.budgetExceeded }
                        let other = candidates[index]
                        if other.sheet == candidate.sheet, other.priority < candidate.priority,
                            (other.point - candidate.point).squaredLength < spacing * spacing { return true }
                    }
                }
            }
        }
        return false
    }

    private mutating func excluded(
        _ point: Vector3, clearance: Float?, sources: [MeshTerrainPopulation.Influence], ignoring sourceID: UInt32?
    ) throws -> Bool {
        guard let clearance else { return false }
        for source in sources where source.sourceID != sourceID {
            try queryBudget.charge()
            guard source.bounds.expanded(by: clearance).contains(point) else { continue }
            let allowance = min(4_096, queryBudget.remaining)
            guard allowance > 0 else { throw TriangleGeometryError.budgetExceeded }
            try queryBudget.charge(allowance)
            if try source.solid.value(at: point, maximumWork: allowance) <= clearance { return true }
        }
        return false
    }

    private mutating func hit(
        _ ray: Ray, distance: Float, patches: [MeshTerrainPopulation.IndexedPatch]
    ) throws -> (patch: MeshTerrainPatch, hit: TriangleSurfaceHit)? {
        var best: (patch: MeshTerrainPatch, hit: TriangleSurfaceHit)?
        for patch in patches {
            let candidate = try patch.value.query.raycast(
                ray, maximumDistance: min(distance, best?.hit.distance.nextUp ?? distance), budget: &queryBudget
            ) { first, second in Face(patch.value.surface, first) < Face(patch.value.surface, second) }
            if let candidate, best == nil || candidate.preciseDistance < (best?.hit.preciseDistance ?? .infinity) {
                best = (patch.value, candidate)
            }
        }
        return best
    }

    private static func hash(_ value: UInt64) -> UInt64 {
        var value = value
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    private static func align(_ normal: Vector3) -> Quat {
        if normal.y < -0.9999 { return Quat(axis: .right, angle: .pi) }
        return Quat(x: normal.z, y: 0, z: -normal.x, w: 1 + normal.y).normalized
    }

    private static func compose(_ a: Quat, _ b: Quat) -> Quat {
        Quat(x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
             y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
             z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
             w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z).normalized
    }
}
