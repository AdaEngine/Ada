import Foundation
import Math

public struct MeshTerrainPopulationRule: Codable, Equatable, Sendable {
    public let id: UUID
    public var prototypeID: UInt16
    public var seed: UInt64
    public var bounds: MeshTerrainBounds
    public var density: Float
    public var spacing: Float
    public var cellSize: Float
    public var minimumUpDot: Float
    public var maximumUpDot: Float
    public var minimumScale: Float
    public var maximumScale: Float
    public var offset: Float
    public var enabled: Bool
    /// Nil preserves legacy rules; new rules reserve this distance around joined sources.
    public var sourceExclusionDistance: Float?
    public var coverage: MeshTerrainPopulationCoverage?

    public init(id: UUID = UUID(), prototypeID: UInt16, seed: UInt64 = 0, bounds: MeshTerrainBounds,
                density: Float = 1, spacing: Float = 0.5, cellSize: Float = 16,
                minimumUpDot: Float = 0.2, maximumUpDot: Float = 1, minimumScale: Float = 0.8,
                maximumScale: Float = 1.2, offset: Float = 0, enabled: Bool = true, sourceExclusionDistance: Float? = 0.5, coverage: MeshTerrainPopulationCoverage? = nil) {
        self.id = id; self.prototypeID = prototypeID; self.seed = seed; self.bounds = bounds
        self.density = density; self.spacing = spacing; self.cellSize = cellSize
        self.minimumUpDot = minimumUpDot; self.maximumUpDot = maximumUpDot
        self.minimumScale = minimumScale; self.maximumScale = maximumScale; self.offset = offset; self.enabled = enabled; self.sourceExclusionDistance = sourceExclusionDistance
        self.coverage = coverage
    }

    public func validate() throws {
        try coverage?.validate()
        if let distance = sourceExclusionDistance { guard distance.isFinite, (0...128).contains(distance) else { throw TriangleGeometryError.invalidInput } }
        guard density.isFinite, (0...100).contains(density), spacing.isFinite, (0.1...128).contains(spacing),
            cellSize.isFinite, (1...256).contains(cellSize), minimumUpDot.isFinite, maximumUpDot.isFinite,
            (-1...1).contains(minimumUpDot), (-1...1).contains(maximumUpDot), minimumUpDot <= maximumUpDot,
            minimumScale.isFinite, maximumScale.isFinite, minimumScale > 0, maximumScale >= minimumScale, maximumScale <= 100,
            offset.isFinite, abs(offset) <= 100, bounds.minimum.x.isFinite, bounds.minimum.y.isFinite, bounds.minimum.z.isFinite,
            bounds.maximum.x.isFinite, bounds.maximum.y.isFinite, bounds.maximum.z.isFinite,
            bounds.minimum.x < bounds.maximum.x, bounds.minimum.y < bounds.maximum.y, bounds.minimum.z < bounds.maximum.z,
            bounds.minimum.x >= -1_000_000, bounds.minimum.y >= -1_000_000, bounds.minimum.z >= -1_000_000,
            bounds.maximum.x <= 1_000_000, bounds.maximum.y <= 1_000_000, bounds.maximum.z <= 1_000_000
        else { throw TriangleGeometryError.invalidInput }
    }
}

public enum MeshTerrainPlacementOwnership: String, Codable, Sendable { case manual, generated, pinned }

public struct MeshTerrainPlacement: Codable, Equatable, Sendable {
    public let id: UInt64
    public var ruleID: UUID?
    public var prototypeID: UInt16
    public var transform: Transform3D
    public var ownership: MeshTerrainPlacementOwnership
    public var patchID: UUID?
    public var normal: Vector3
    public var sourceID: UInt32

    public init(id: UInt64, ruleID: UUID? = nil, prototypeID: UInt16, transform: Transform3D,
                ownership: MeshTerrainPlacementOwnership = .manual, patchID: UUID? = nil,
                normal: Vector3 = .up, sourceID: UInt32 = 0) {
        self.id = id; self.ruleID = ruleID; self.prototypeID = prototypeID; self.transform = transform
        self.ownership = ownership; self.patchID = patchID; self.normal = normal; self.sourceID = sourceID
    }
}

public struct MeshTerrainPopulationOverride: Codable, Equatable, Sendable {
    public let ruleID: UUID
    public let candidateID: UInt64
    public var pinned: MeshTerrainPlacement?
    public var suppressed: Bool
    public init(ruleID: UUID, candidateID: UInt64, pinned: MeshTerrainPlacement? = nil, suppressed: Bool = false) {
        self.ruleID = ruleID; self.candidateID = candidateID; self.pinned = pinned; self.suppressed = suppressed
    }
}

public struct MeshTerrainPopulationSnapshot: Sendable {
    public let placements: [MeshTerrainPlacement]
    public let orphanedPins: [MeshTerrainPlacement]
    public let visitedCandidates: Int
}

/// Spatial candidate ownership is independent of triangle enumeration and camera
/// placement. Three-axis projection covers floors, walls and ceilings. A bounded
/// priority exclusion rule makes spacing independent of worker/cell order.
public enum MeshTerrainPopulation {
    public static func evaluate(
        _ rules: [MeshTerrainPopulationRule], surface: MeshTerrainSurfaceSnapshot,
        document: MeshTerrainDocument? = nil, exclusions: [MeshTerrainBounds] = [], manual: [MeshTerrainPlacement] = [],
        overrides: [MeshTerrainPopulationOverride] = [], maximumCandidates: Int = 262_144
    ) throws -> MeshTerrainPopulationSnapshot {
        var cache = Cache()
        return try evaluate(rules, surface: surface, document: document, exclusions: exclusions, manual: manual,
                            overrides: overrides, maximumCandidates: maximumCandidates, cache: &cache)
    }

    static func evaluate(
        _ rules: [MeshTerrainPopulationRule], surface: MeshTerrainSurfaceSnapshot, document: MeshTerrainDocument?,
        exclusions: [MeshTerrainBounds] = [], manual: [MeshTerrainPlacement], overrides: [MeshTerrainPopulationOverride],
        maximumCandidates: Int = 262_144, cache: inout Cache
    ) throws -> MeshTerrainPopulationSnapshot {
        guard rules.count <= 128, manual.count <= 262_144, overrides.count <= 262_144, exclusions.count <= 4_096,
            maximumCandidates > 0, maximumCandidates <= 1_048_576 else { throw TriangleGeometryError.budgetExceeded }
        var pass = try CellPass(surface: surface, previous: cache, maximumCandidates: maximumCandidates)
        var placements = manual, orphans: [MeshTerrainPlacement] = []
        let ruleOverrides = Dictionary(grouping: overrides, by: \.ruleID)
        for rule in rules {
            try rule.validate()
            let overrides = ruleOverrides[rule.id] ?? []
            var byID: [UInt64: MeshTerrainPopulationOverride] = [:]
            for override in overrides where byID[override.candidateID] == nil { byID[override.candidateID] = override }
            var admitted: Set<UInt64> = []
            for candidate in try pass.generate(rule, document: document, exclusions: exclusions) where admitted.insert(candidate.id).inserted {
                if let override = byID[candidate.id] {
                    if override.suppressed { continue }
                    if var pinned = override.pinned { pinned.ownership = .pinned; placements.append(pinned); continue }
                }
                placements.append(candidate)
            }
            try retainPins(overrides, admitted: admitted, rule: rule, surface: surface, placements: &placements, orphans: &orphans, budget: &pass.queryBudget)
            guard placements.count <= maximumCandidates + manual.count else { throw TriangleGeometryError.budgetExceeded }
        }
        try Task.checkCancellation()
        cache = pass.staged
        return .init(placements: placements.sorted { $0.id < $1.id }, orphanedPins: orphans, visitedCandidates: pass.visitedCandidates)
    }

    private static func retainPins(
        _ overrides: [MeshTerrainPopulationOverride],
        admitted: Set<UInt64>,
        rule: MeshTerrainPopulationRule,
        surface: MeshTerrainSurfaceSnapshot,
        placements: inout [MeshTerrainPlacement],
        orphans: inout [MeshTerrainPlacement],
        budget: inout TriangleSurfaceQueryBudget
    ) throws {
        var checked = admitted
        for override in overrides where checked.insert(override.candidateID).inserted {
            try budget.charge()
            guard !override.suppressed, var pin = override.pinned else { continue }
            pin.ownership = .pinned
            if try supports(pin, offset: rule.offset, surface: surface, budget: &budget) { placements.append(pin) }
            else { orphans.append(pin) }
        }
    }

    private static func supports(_ pin: MeshTerrainPlacement, offset: Float, surface: MeshTerrainSurfaceSnapshot,
                                 budget: inout TriangleSurfaceQueryBudget) throws -> Bool {
        guard pin.normal.squaredLength.isFinite, pin.normal.squaredLength > 0.000001 else { return false }
        let direction = pin.normal.normalized
        let point = pin.transform.origin - direction * offset
        for patch in surface.patches where pin.patchID == nil || pin.patchID == patch.id {
            try budget.charge()
            let hit = try patch.query.closest(to: point, maximumDistance: 0.75, budget: &budget) { face, normal in
                let source = patch.surface.faceSources.isEmpty ? 0 : patch.surface.faceSources[face]
                return source == pin.sourceID && direction.dot(normal) >= 0.5
            }
            if hit != nil { return true }
        }
        return false
    }

}
