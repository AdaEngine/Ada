import AdaECS
import AdaGeometry
import AdaPhysics
import AdaTransform
import Math

/// Portable static triangle collision. The scene loader places its local surface
/// after resolving parents and scene instances.
public struct StaticTriangleMesh3DSource: Codable, Sendable {
    private let positions: [Vector3]
    private let indices: [UInt32]

    public init(surface: TriangleSurface) {
        // Box3D uses shared indices to identify adjacent triangles. UV seams
        // split render vertices but must share the same collision vertex.
        var exactIndices: [Vector3: UInt32] = [:]
        var welded: [Vector3] = []
        let remap = surface.positions.map { position in
            if let index = exactIndices[position] {
                return index
            }
            let index = UInt32(welded.count)
            exactIndices[position] = index
            welded.append(position)
            return index
        }
        positions = welded
        indices = surface.indices.map { index in remap.indices.contains(Int(index)) ? remap[Int(index)] : index }
    }

    public func makeShape(worldMatrix: Transform3D) throws -> Shape3DResource {
        let local = TriangleSurface(positions: positions, indices: indices)
        let placed = try local.transformed(by: worldMatrix)
        return try Shape3DResource.generateTriangleMesh(vertices: placed.positions, indices: placed.indices)
    }

    /// Place a static body after the scene has connected the entity hierarchy.
    /// The resulting world-space body needs an identity transform.
    @MainActor
    public func makeBody(for entity: Entity) throws -> PhysicsBody3DComponent? {
        var current: Entity? = entity
        var visited: Set<Entity.ID> = []
        var pose = Transform3D.identity
        var inheritsTransform = true
        while let value = current {
            guard value.isActive else {
                return nil
            }
            guard visited.insert(value.id).inserted else { throw TriangleGeometryError.invalidInput }
            if inheritsTransform {
                if let transform = value.components[Transform.self] {
                    pose = transform.matrix * pose
                } else {
                    inheritsTransform = false
                }
            }
            current = value.parent
        }
        return try PhysicsBody3DComponent(shapes: [makeShape(worldMatrix: pose)], mode: .static)
    }
}
