import Foundation
import Math

/// Ordered brush coverage for one generated prototype rule. Manual placements
/// and pinned overrides are separate records and are not written by this mask.
public struct MeshTerrainPopulationCoverage: Codable, Equatable, Sendable {
    public struct Stamp: Codable, Equatable, Sendable {
        public enum Operation: Codable, Equatable, Sendable {
            case include(density: Float)
            case erase
        }

        public let anchor: MeshTerrainSurfaceAnchor
        public let radius: Float
        public let operation: Operation

        public init(anchor: MeshTerrainSurfaceAnchor, radius: Float, operation: Operation) {
            self.anchor = anchor
            self.radius = radius
            self.operation = operation
        }

        func validate() throws {
            try anchor.validate()
            guard radius.isFinite, radius > 0, radius <= 128 else { throw TriangleGeometryError.invalidInput }
            if case let .include(density) = operation {
                guard density.isFinite, (0...1).contains(density) else { throw TriangleGeometryError.invalidInput }
            }
        }
    }

    public static let maximumStamps = 1_024
    public let stamps: [Stamp]

    public init(stamps: [Stamp]) {
        self.stamps = stamps
    }

    private enum CodingKeys: CodingKey { case stamps }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stamps = try MeshTerrainDecoding.list(Stamp.self, key: .stamps, in: container, decoder: decoder, maximum: Self.maximumStamps)
        try validate()
    }

    func validate() throws {
        guard stamps.count <= Self.maximumStamps else { throw TriangleGeometryError.budgetExceeded }
        for stamp in stamps { try stamp.validate() }
    }

    func resolve(in document: MeshTerrainDocument, limitedTo bounds: MeshTerrainBounds) throws -> MeshTerrainResolvedCoverage {
        var resolved: [MeshTerrainResolvedCoverage.Stamp] = []
        var inclusion: MeshTerrainBounds?
        for stamp in stamps {
            try Task.checkCancellation()
            guard let anchor = try stamp.anchor.resolved(in: document) else { continue }
            let volume = MeshTerrainBounds(minimum: anchor.point - Vector3(stamp.radius), maximum: anchor.point + Vector3(stamp.radius))
            guard bounds.intersects(volume) else { continue }
            if case .include = stamp.operation { inclusion = inclusion.map { $0.union(volume) } ?? volume }
            resolved.append(.init(point: anchor.point, normal: anchor.normal, sourceID: anchor.sourceID,
                baseSection: anchor.sourceID == 0 ? stamp.anchor.section : nil, radius: stamp.radius, operation: stamp.operation))
        }
        let domain = inclusion.flatMap { volume -> MeshTerrainBounds? in
            let low = max(bounds.minimum, volume.minimum), high = min(bounds.maximum, volume.maximum)
            guard low.x < high.x, low.y < high.y, low.z < high.z else { return nil }
            return .init(minimum: low, maximum: high)
        }
        return .init(stamps: resolved, domain: domain)
    }
}

struct MeshTerrainResolvedCoverage: Sendable {
    struct Stamp: Codable, Equatable, Sendable {
        let point: Vector3
        let normal: Vector3
        let sourceID: UInt32
        let baseSection: UUID?
        let radius: Float
        let operation: MeshTerrainPopulationCoverage.Stamp.Operation

        var bounds: MeshTerrainBounds { .init(minimum: point - Vector3(radius), maximum: point + Vector3(radius)) }
    }

    let stamps: [Stamp]
    let domain: MeshTerrainBounds?

    func density(at point: Vector3, normal: Vector3, source: UInt32, patch: UUID, budget: inout TriangleSurfaceQueryBudget) throws -> Float {
        try budget.charge(stamps.count)
        var weight: Float = 0
        for stamp in stamps {
            guard stamp.sourceID == source, stamp.baseSection == nil || stamp.baseSection == patch,
                stamp.normal.dot(normal) >= 0.5 else { continue }
            let offset = point - stamp.point
            let distance = offset.length
            // Limit through-surface influence even for a wide brush.
            guard distance < stamp.radius, abs(offset.dot(stamp.normal)) <= min(0.75, stamp.radius * 0.25) else { continue }
            switch stamp.operation {
            case let .include(density):
                let t = min(1, (1 - distance / stamp.radius) * 3)
                weight = max(weight, density * t * t * (3 - 2 * t))
            case .erase: weight = 0
            }
        }
        return weight
    }
}
