import Foundation
import Math

/// Compiles durable paint onto the accepted triangle topology without modifying
/// the query or collision mesh. Ownership is checked before walking each sheet.
public enum MeshTerrainPaintBaker {
    public struct Result: Sendable {
        public let patches: [UUID: MeshTerrainCompiledPaint]
        public let orphans: [UUID]
    }

    private struct Match {
        let patch: Int
        let hit: TriangleSurfaceHit
    }

    public static func bake(document: MeshTerrainDocument, surface: MeshTerrainSurfaceSnapshot, budget: TriangleGeometryBudget) throws -> Result {
        guard !document.paint.isEmpty else { return .init(patches: [:], orphans: []) }
        var work = try TriangleSurfaceQueryBudget(maximumWork: min(budget.maximumCandidatePairs, 16_777_216))
        var byPatch: [Int: [MeshTerrainPaintBrush]] = [:], orphans: [UUID] = []
        for stamp in document.paint where stamp.strength > 0 {
            try Task.checkCancellation()
            guard let resolved = try stamp.anchor.resolved(in: document) else { orphans.append(stamp.id); continue }
            let tolerance = min(0.5, max(0.001, stamp.radius * 0.25))
            let match = try locate(stamp.anchor, resolved: resolved, tolerance: tolerance, patches: surface.patches, work: &work)
            guard let match else { orphans.append(stamp.id); continue }
            byPatch[match.patch, default: []].append(.init(stamp: stamp, hit: match.hit, source: resolved.sourceID, normal: resolved.normal))
        }
        var patches: [UUID: MeshTerrainCompiledPaint] = [:], remaining = min(budget.maximumBytes, 64 * 1_024 * 1_024)
        for (index, patch) in surface.patches.enumerated() {
            guard let brushes = byPatch[index] else { continue }
            let scratch = patch.surface.indices.count * 160 + patch.surface.positions.count * 80
            guard scratch <= remaining else { throw TriangleGeometryError.budgetExceeded }
            let topology = try MeshTerrainPaintTopology(surface: patch.surface, work: &work)
            var samples: [Int: [MeshTerrainCompiledPaint.Sample.Layer]] = [:]
            let sampleLimit = min(262_144, (remaining - scratch) / 384)
            for brush in brushes {
                let applied = try topology.apply(brush, samples: &samples, sampleLimit: sampleLimit, work: &work)
                if !applied { orphans.append(brush.stamp.id) }
            }
            remaining -= samples.count * 384
            if !samples.isEmpty {
                patches[patch.id] = .init(samples: samples.sorted { $0.key < $1.key }.map { .init(corner: $0.key, layers: $0.value) })
            }
        }
        let orphanIDs = Set(orphans)
        return .init(patches: patches, orphans: document.paint.map(\.id).filter { orphanIDs.contains($0) })
    }

    private static func locate(
        _ anchor: MeshTerrainSurfaceAnchor,
        resolved: (point: Vector3, normal: Vector3, sourceID: UInt32),
        tolerance: Float,
        patches: [MeshTerrainPatch],
        work: inout TriangleSurfaceQueryBudget
    ) throws -> Match? {
        // Prefer the original face provenance; do not migrate to another surface
        // on account of a slightly closer face after a split or a retessellation.
        for exact in [true, false] {
            var best: Match?
            for (index, patch) in patches.enumerated() {
                try work.charge()
                if resolved.sourceID == 0, patch.id != anchor.section { continue }
                let limit = min(tolerance, best?.hit.distance.nextUp ?? tolerance)
                let hit = try patch.query.closest(to: resolved.point, maximumDistance: limit, budget: &work) { face, normal in
                    let owner = patch.surface.faceSources.isEmpty ? 0 : patch.surface.faceSources[face]
                    let faceID = patch.surface.faceIDs.isEmpty ? UInt32(face) : patch.surface.faceIDs[face]
                    return owner == resolved.sourceID && normal.dot(resolved.normal) >= 0.5 && (!exact || faceID == anchor.faceID)
                }
                if let hit, hit.preciseDistance < (best?.hit.preciseDistance ?? .infinity) { best = .init(patch: index, hit: hit) }
            }
            if let best { return best }
        }
        return nil
    }
}
