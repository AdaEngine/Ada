@_spi(AdaEngine) import AdaEngine
// swiftlint:disable:next duplicate_imports
@_spi(Internal) import AdaEngine
import Math

/// Broad-phase boxes only reject candidates. A static mesh is selected at its actual surface,
/// so merged city geometry and empty space inside its bounds cannot hide another model.
@MainActor
enum EditorMeshPicking {
    private struct Candidate {
        let editorID: String
        let ray: Ray
        let minimumDistance: Float
        let mesh: Mesh?
        let skin: [Transform3D]
        let usesBounds: Bool
    }

    static func pick(ray: Ray, world: World, authoredEntities: [String: Entity.ID], editorIDs: [Entity.ID: String], cameraID: Entity.ID?) -> String? {
        var candidates: [Candidate] = []
        var animatedBounds = AnimatedBounds3D()
        for entity in world.getEntities() {
            guard entity.id != cameraID, let editorID = editorIDs[entity.id],
                let matrix = EditorPicking.worldMatrix(for: entity, requiringVisible: true),
                let localRay = EditorPicking.localRay(ray, matrix: matrix) else { continue }
            if let component = entity.components[Mesh3DComponent.self] {
                let mesh = component.mesh
                let skin = entity.components[SkinnedMesh3DComponent.self]?.matrices ?? []
                let weights = entity.components[MorphWeights3DComponent.self]?.weights ?? []
                let isMorphed = mesh.hasMorphTargets && weights.contains { $0.isFinite && $0 != 0 }
                let hasTriangles = mesh.models.contains { $0.parts.contains { $0.primitiveTopology == .triangleList || $0.primitiveTopology == .triangleStrip } }
                var bounds = skin.isEmpty ? mesh.bounds : animatedBounds.bounds(mesh: mesh, matrices: skin)
                if isMorphed, let current = bounds {
                    let displacement = mesh.models.reduce(Float(0)) { value, model in
                        model.parts.reduce(value) { max($0, $1.morphTargets?.maximumDisplacement(for: weights) ?? 0) }
                    }
                    let scale = skin.reduce(Float(1)) { max($0, $1.x.xyz.length, $1.y.xyz.length, $1.z.xyz.length) }
                    let growth = Vector3(displacement * scale)
                    bounds = AABB(min: current.min - growth, max: current.max + growth)
                }
                // An unbounded skin still needs a triangle test; it cannot be rejected using rest-pose bounds.
                let minimumDistance = bounds.flatMap { EditorPicking.rayAABBIntersectionDistance(ray: localRay, aabb: $0) }
                guard bounds == nil || minimumDistance != nil else { continue }
                candidates.append(Candidate(editorID: editorID, ray: localRay, minimumDistance: minimumDistance ?? 0,
                                            mesh: mesh, skin: skin, usesBounds: (isMorphed && bounds != nil) || !hasTriangles))
            } else {
                // Imported roots and transform-only generated groups have no selectable surface.
                // Keep the small bounds fallback for authored cameras, lights and empty entities.
                guard authoredEntities[editorID] == entity.id, entity.components[Model3DSource.self] == nil,
                    let distance = EditorPicking.intersectionDistance(ray: ray, matrix: matrix, bounds: entity.components[BoundingComponent.self]) else { continue }
                candidates.append(Candidate(editorID: editorID, ray: localRay, minimumDistance: distance, mesh: nil, skin: [], usesBounds: true))
            }
        }
        candidates.sort { $0.minimumDistance < $1.minimumDistance }
        var selectedID: String?
        var nearest = Float.greatestFiniteMagnitude
        for candidate in candidates {
            if candidate.minimumDistance > nearest { break }
            let distance: Float?
            if let mesh = candidate.mesh, !candidate.usesBounds {
                distance = intersectionDistance(ray: candidate.ray, mesh: mesh, skin: candidate.skin, maximumDistance: nearest)
            } else {
                // Morph deltas currently live in a GPU texture. Preserve conservative picking for those poses.
                distance = candidate.minimumDistance
            }
            if let distance, distance < nearest {
                nearest = distance
                selectedID = candidate.editorID
            }
        }
        return selectedID
    }

    private static func intersectionDistance(ray: Ray, mesh: Mesh, skin: [Transform3D], maximumDistance: Float) -> Float? {
        var nearest = maximumDistance
        var hit = false
        for model in mesh.models {
            for part in model.parts {
                let descriptor = part.meshDescriptor
                var positions = descriptor.positions.elements
                if !skin.isEmpty, let joints = descriptor[MeshDescriptor.jointIndices]?.elements,
                    let weights = descriptor[MeshDescriptor.jointWeights]?.elements,
                    joints.count == positions.count, weights.count == positions.count {
                    for index in positions.indices {
                        let point = Vector4(positions[index], 1)
                        var posed = Vector4.zero
                        for lane in 0..<4 where weights[index][lane] > 0 {
                            let joint = joints[index][lane]
                            guard joint.isFinite, joint >= 0, joint < Float(skin.count) else { continue }
                            posed += skin[Int(joint)] * point * weights[index][lane]
                        }
                        positions[index] = posed.xyz
                    }
                }
                let indices = descriptor.indicies
                let count = indices.isEmpty ? positions.count : indices.count
                let step: Int
                switch part.primitiveTopology {
                case .triangleList: step = 3
                case .triangleStrip: step = 1
                default: continue
                }
                guard count >= 3 else { continue }
                for offset in stride(from: 0, through: count - 3, by: step) {
                    let a = indices.isEmpty ? offset : Int(indices[offset])
                    let b = indices.isEmpty ? offset + 1 : Int(indices[offset + 1])
                    let c = indices.isEmpty ? offset + 2 : Int(indices[offset + 2])
                    guard positions.indices.contains(a), positions.indices.contains(b), positions.indices.contains(c),
                        let distance = triangleDistance(ray: ray, a: positions[a], b: positions[b], c: positions[c]), distance <= nearest else { continue }
                    nearest = distance
                    hit = true
                }
            }
        }
        return hit ? nearest : nil
    }

    nonisolated static func triangleDistance(ray: Ray, a: Vector3, b: Vector3, c: Vector3) -> Float? {
        let edge = b - a
        let secondEdge = c - a
        let cross = ray.direction.cross(secondEdge)
        let determinant = edge.dot(cross)
        // A relative tolerance works for both metre-sized and very small imported geometry.
        guard determinant.isFinite, abs(determinant) > Float.ulpOfOne * Math.sqrt(edge.squaredLength * cross.squaredLength) else { return nil }
        let inverse = 1 / determinant
        let offset = ray.origin - a
        let u = offset.dot(cross) * inverse
        guard u >= 0, u <= 1 else { return nil }
        let q = offset.cross(edge)
        let v = ray.direction.dot(q) * inverse
        guard v >= 0, u + v <= 1 else { return nil }
        let distance = secondEdge.dot(q) * inverse
        return distance.isFinite && distance >= 0 ? distance : nil
    }
}
