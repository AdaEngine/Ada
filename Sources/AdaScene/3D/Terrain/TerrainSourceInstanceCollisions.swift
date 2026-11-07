import AdaAssets
import AdaCorePipelines
@_spi(Internal) import AdaRender
import Foundation
import Math

/// Captured only when placement rows change; decorative cells retain an empty candidate array.
struct TerrainCollisionPlacement: Sendable {
    let record: TerrainRegionInstance
    let transform: Transform3D
}

struct TerrainPreparedInstanceCollider: Sendable {
    let id = UUID()
    let record: TerrainRegionInstance
    let prototype: UUID
    let matrix: Transform3D
    let descriptor: MeshDescriptor
    let chargedBytes: Int
}

struct TerrainSourceInstanceCollider: Sendable {
    let prepared: TerrainPreparedInstanceCollider
    let entity: Int
}

enum TerrainSourceInstanceCollisions {
    private struct Candidate {
        let distance: Float
        let placement: TerrainCollisionPlacement
        let prototype: TerrainMeshPrototype
    }

    private static func candidates(
        cells: [TerrainInstanceCellKey: TerrainPreparedInstanceCell],
        prototypes: [UInt16: TerrainMeshPrototype],
        cameras: [Vector3],
        physics: TerrainPhysicsInterests,
        matrix: Transform3D,
        source: Terrain3DSource
    ) throws -> [Candidate] {
        let limits = source.instanceCollision
        guard source.generatesCollision, limits.maximumCount > 0 else {
            return []
        }
        let inverse = matrix.inverse
        let cameraPoints = cameras.map { (inverse * Vector4($0, 1)).xyz }
        guard !cameraPoints.isEmpty || !physics.isEmpty else {
            return []
        }
        var candidates: [Candidate] = []
        var visits = 0
        for key in cells.keys.sorted() {
            guard let cell = cells[key], !cell.collisionPlacements.isEmpty else { continue }
            guard let prototype = prototypes[key.prototype] else { throw TerrainSourceError.changedDuringBuild }
            for placement in cell.collisionPlacements {
                visits += 1
                guard visits <= 262_144 else { throw TerrainSourceError.instanceCollisionBudgetExceeded }
                if visits.isMultiple(of: 256) { try Task.checkCancellation() }
                let bounds = MeshVisibility3DMath.transformed(prototype.bounds, by: placement.transform)
                var distance = physics.requiresAllRegions ? Float(0) : Float.infinity
                for point in cameraPoints { distance = min(distance, separation(bounds.min.x, bounds.max.x, point.x, point.x) + separation(bounds.min.z, bounds.max.z, point.z, point.z)) }
                for rectangle in physics.rectangles {
                    distance = min(distance, separation(bounds.min.x, bounds.max.x, rectangle.min.x, rectangle.max.x)
                        + separation(bounds.min.z, bounds.max.z, rectangle.min.y, rectangle.max.y))
                }
                if distance <= limits.distance * limits.distance { candidates.append(.init(distance: distance, placement: placement, prototype: prototype)) }
            }
        }
        try Task.checkCancellation()
        candidates.sort { $0.distance == $1.distance ? $0.placement.record.id < $1.placement.record.id : $0.distance < $1.distance }
        return Array(candidates.prefix(limits.maximumCount))
    }

    /// Uses the same bounded selection as publication, without allocating geometry or native bodies.
    static func requiredIDs(state: TerrainSourceState, physics: TerrainPhysicsInterests, source: Terrain3DSource) throws -> [UInt64] {
        try candidates(
            cells: state.instanceCells.mapValues(\.prepared),
            prototypes: state.residency?.prototypes ?? [:],
            cameras: state.focus?.cameras ?? [],
            physics: .init(rectangles: physics.rectangles, requiresAllRegions: physics.requiresAllRegions || state.focus?.allCameraRegions == true),
            matrix: state.matrix,
            source: source
        ).map { $0.placement.record.id }
    }

    static func prepare(
        cells: [TerrainInstanceCellKey: TerrainPreparedInstanceCell],
        prototypes: [UInt16: TerrainMeshPrototype],
        cameras: [Vector3],
        physics: TerrainPhysicsInterests,
        matrix: Transform3D,
        source: Terrain3DSource,
        previous: [UInt64: TerrainPreparedInstanceCollider]
    ) throws -> [UInt64: TerrainPreparedInstanceCollider] {
        let selected = try candidates(cells: cells, prototypes: prototypes, cameras: cameras, physics: physics, matrix: matrix, source: source)
        var result: [UInt64: TerrainPreparedInstanceCollider] = [:]
        var remaining = source.instanceCollision.maximumBytes
        for candidate in selected {
            try Task.checkCancellation()
            let record = candidate.placement.record, local = candidate.placement.transform
            if let old = previous[record.id], old.record == record, old.prototype == candidate.prototype.collisionGeometryID, old.matrix == local {
                guard old.chargedBytes <= remaining else { throw TerrainSourceError.instanceCollisionBudgetExceeded }
                remaining -= old.chargedBytes; result[record.id] = old
                continue
            }
            let geometry = try geometry(candidate.prototype, matrix: local, maximumBytes: remaining)
            remaining -= geometry.bytes
            result[record.id] = .init(record: record, prototype: candidate.prototype.collisionGeometryID, matrix: local, descriptor: geometry.descriptor, chargedBytes: geometry.bytes)
        }
        return result
    }

    private static func separation(_ lower: Float, _ upper: Float, _ otherLower: Float, _ otherUpper: Float) -> Float {
        let gap = max(0, max(lower - otherUpper, otherLower - upper))
        return gap * gap
    }

    private static func geometry(_ prototype: TerrainMeshPrototype, matrix: Transform3D, maximumBytes: Int) throws -> (descriptor: MeshDescriptor, bytes: Int) {
        var descriptor = MeshDescriptor(name: "Terrain static placement collision")
        var vertices: [Vector3] = [], indices: [UInt32] = []
        var remaining = maximumBytes
        // Conservative transformed/old/new CPU geometry, native copies and BVH allowance per referenced index.
        let charge = MemoryLayout<Vector3>.stride * 4 + MemoryLayout<UInt32>.stride * 4 + 64
        for node in prototype.parts {
            let transform = matrix * node.transform
            for model in node.mesh.models {
                for part in model.parts {
                    try Task.checkCancellation()
                    let source = part.meshDescriptor
                    let count = min(part.indexCount, source.indicies.count)
                    guard count.isMultiple(of: 3), count <= remaining / charge else { throw TerrainSourceError.instanceCollisionBudgetExceeded }
                    remaining -= count * charge
                    let positions = source.positions.elements
                    var remapped: [UInt32: UInt32] = [:]
                    let first = indices.count
                    for (offset, index) in source.indicies.prefix(count).enumerated() {
                        if offset.isMultiple(of: 1_024) { try Task.checkCancellation() }
                        guard positions.indices.contains(Int(index)) else { throw TerrainSourceError.changedDuringBuild }
                        if let value = remapped[index] { indices.append(value) } else {
                            let position = (transform * Vector4(positions[Int(index)], 1)).xyz
                            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { throw TerrainSourceError.invalidTransform }
                            let value = UInt32(vertices.count)
                            vertices.append(position); remapped[index] = value; indices.append(value)
                        }
                    }
                    if transform.determinant < 0 {
                        for index in stride(from: first, to: indices.count, by: 3) { indices.swapAt(index + 1, index + 2) }
                    }
                }
            }
        }
        descriptor.positions = MeshBuffer(vertices); descriptor.indicies = indices
        return (descriptor, maximumBytes - remaining)
    }
}
