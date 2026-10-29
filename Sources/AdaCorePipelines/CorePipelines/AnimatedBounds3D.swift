import AdaECS
@_spi(Internal) import AdaRender
import Foundation
import Math

/// Caches rest-space influence envelopes. Their transformed union bounds any normalized,
/// non-negative linear-blend skin pose without skinning every vertex on the CPU each frame.
public struct AnimatedBounds3D: Resource {
    private struct Entry { var buffer: any VertexBuffer; var envelopes: [AABB?] }
    private var cache: [ObjectIdentifier: Entry] = [:]
    private var seen: Set<ObjectIdentifier> = []
    private struct MergedEntry { var buffers: [any VertexBuffer]; var envelopes: [AABB?] }
    private var merged: [[ObjectIdentifier]: MergedEntry] = [:]
    private var seenMerged: Set<[ObjectIdentifier]> = []
    private struct PoseEntry {
        let revision: SkinningPoseRevision
        let buffers: [ObjectIdentifier]
        let matrixCount: Int
        let bounds: AABB?
    }
    private var poses: [UUID: PoseEntry] = [:]
    private var seenPoses: Set<UUID> = []
    public init() {}

    public mutating func beginFrame() {
        seen.removeAll(keepingCapacity: true)
        seenMerged.removeAll(keepingCapacity: true)
        seenPoses.removeAll(keepingCapacity: true)
    }
    public mutating func finishFrame() {
        for key in cache.keys where !seen.contains(key) { cache.removeValue(forKey: key) }
        for key in merged.keys where !seenMerged.contains(key) { merged.removeValue(forKey: key) }
        for key in poses.keys where !seenPoses.contains(key) { poses.removeValue(forKey: key) }
    }

    /// Reuses model-local bounds while the component-owned palette revision and geometry are unchanged.
    /// Camera and world transforms do not change the local pose. Callers must advance the revision when matrices change.
    public mutating func bounds(meshes: [Mesh], matrices: [Transform3D], revision: SkinningPoseRevision) -> AABB? {
        let buffers = meshes.flatMap { $0.models.flatMap { $0.parts.map { ObjectIdentifier($0.vertexBuffer) } } }
        seenPoses.insert(revision.id)
        if let pose = poses[revision.id], pose.revision == revision, pose.buffers == buffers, pose.matrixCount == matrices.count {
            // Keep the influence envelopes alive too, so resuming a paused animation needs no vertex scan.
            seen.formUnion(buffers)
            if meshes.count > 1 { seenMerged.insert(buffers) }
            return pose.bounds
        }
        let result = meshes.count == 1 ? bounds(mesh: meshes[0], matrices: matrices) : bounds(meshes: meshes, matrices: matrices)
        poses[revision.id] = PoseEntry(revision: revision, buffers: buffers, matrixCount: matrices.count, bounds: result)
        return result
    }

    /// Unions rest-space envelopes once across LODs, then transforms each joint only once per pose.
    public mutating func bounds(meshes: [Mesh], matrices: [Transform3D]) -> AABB? {
        let buffers = meshes.flatMap { $0.models.flatMap { $0.parts.map(\.vertexBuffer) } }
        let key = buffers.map(ObjectIdentifier.init)
        seenMerged.insert(key)
        for id in key { seen.insert(id) }
        if merged[key]?.envelopes.count != matrices.count {
            for mesh in meshes {
                guard bounds(mesh: mesh, matrices: matrices) != nil else {
                    return nil
                }
            }
            var boxes = [AABB?](repeating: nil, count: matrices.count)
            for id in key {
                guard let part = cache[id]?.envelopes, part.count == matrices.count else {
                    return nil
                }
                for index in part.indices { if let box = part[index] { boxes[index] = union(boxes[index], box) } }
            }
            merged[key] = MergedEntry(buffers: buffers, envelopes: boxes)
        }
        guard let boxes = merged[key]?.envelopes else {
            return nil
        }
        var result: AABB?
        for index in boxes.indices { if let box = boxes[index] { result = union(result, MeshVisibility3DMath.transformed(box, by: matrices[index])) } }
        return result
    }

    public mutating func bounds(mesh: Mesh, matrices: [Transform3D]) -> AABB? {
        var result: AABB?
        for model in mesh.models {
            for part in model.parts {
                let key = ObjectIdentifier(part.vertexBuffer)
                seen.insert(key)
                if cache[key] == nil {
                    let descriptor = part.meshDescriptor
                    guard let joints = descriptor[MeshDescriptor.jointIndices], let weights = descriptor[MeshDescriptor.jointWeights],
                          joints.count == descriptor.positions.count, weights.count == joints.count
                    else {
                        return nil
                    }
                    let positions = Array(descriptor.positions)
                    let jointValues = Array(joints), weightValues = Array(weights)
                    var boxes = [AABB?](repeating: nil, count: matrices.count)
                    for index in positions.indices {
                        let point = positions[index]
                        let js = jointValues[index], ws = weightValues[index]
                        let indices = [js.x, js.y, js.z, js.w], influences = [ws.x, ws.y, ws.z, ws.w]
                        guard influences.allSatisfy({ $0.isFinite && $0 >= 0 }), abs(influences.reduce(0, +) - 1) < 0.001 else {
                            return nil
                        }
                        for lane in 0 ..< 4 where influences[lane] > 0 {
                            let joint = indices[lane]
                            guard joint.isFinite, joint >= 0, joint < Float(matrices.count) else {
                                return nil
                            }
                            let j = Int(joint)
                            boxes[j] = union(boxes[j], AABB(min: point, max: point))
                        }
                    }
                    cache[key] = Entry(buffer: part.vertexBuffer, envelopes: boxes)
                }
                guard let boxes = cache[key]?.envelopes, boxes.count == matrices.count else {
                    return nil
                }
                for index in boxes.indices {
                    if let box = boxes[index] { result = union(result, MeshVisibility3DMath.transformed(box, by: matrices[index])) }
                }
            }
        }
        return result
    }
}

func union(_ lhs: AABB?, _ rhs: AABB) -> AABB {
    guard let lhs else {
        return rhs
    }
    return AABB(min: min(lhs.min, rhs.min), max: max(lhs.max, rhs.max))
}
