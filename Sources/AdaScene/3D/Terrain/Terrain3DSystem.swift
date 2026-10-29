import AdaECS
import AdaPhysics
@_spi(Internal) import AdaRender
import AdaTransform
import Math

private struct Terrain3DRuntimeState: Component {
    var source: Terrain3D
    var matrix: Transform3D
    var collider: Entity.ID?
}

/// Rebuilds an authored terrain only when its height field, appearance or transform changes.
@PlainSystem
public struct Terrain3DSystem {
    @Query<Entity, Terrain3D> private var terrains
    @Query<Entity, Terrain3DRuntimeState> private var builtTerrains
    @Commands private var commands

    public init(world _: World) {}

    public func update(context _: UpdateContext) async {
        terrains.forEach { entity, terrain in
            let matrix = Self.worldMatrix(entity)
            let state = entity.components[Terrain3DRuntimeState.self]
            guard state?.source != terrain || state?.matrix != matrix else { return }
            let id = entity.id
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Terrain3D.self] == terrain,
                      let engine = unsafe RenderEngine.shared, let descriptor = try? terrain.meshDescriptor() else { return }
                if let collider = owner.components[Terrain3DRuntimeState.self]?.collider {
                    world.removeEntity(collider, recursively: true)
                }
                let material = PBRMaterial()
                material.baseColorFactor = terrain.color
                material.roughnessFactor = 0.95
                owner.components[Mesh3DComponent.self] = Mesh3DComponent(
                    mesh: Mesh.generate(from: [descriptor], renderDevice: engine.renderDevice), materials: [material]
                )
                var colliderID: Entity.ID?
                var collisionIndices = descriptor.indicies
                if matrix.determinant < 0 {
                    for index in stride(from: 0, to: collisionIndices.count, by: 3) {
                        collisionIndices.swapAt(index + 1, index + 2)
                    }
                }
                if terrain.generatesCollision, world.getResource(Physics3DWorldHolder.self) != nil,
                   let shape = try? Shape3DResource.generateTriangleMesh(
                    vertices: descriptor.positions.elements.map { (matrix * Vector4($0, 1)).xyz }, indices: collisionIndices
                   ) {
                    // Physics bodies use world transforms. Bake parent scale/rotation into the vertices.
                    let collider = world.spawn("Terrain Collision")
                    collider.components[Transform.self] = Transform()
                    collider.components[PhysicsBody3DComponent.self] = PhysicsBody3DComponent(shapes: [shape], mode: .static)
                    owner.addChild(collider)
                    colliderID = collider.id
                }
                owner.components[Terrain3DRuntimeState.self] = Terrain3DRuntimeState(source: terrain, matrix: matrix, collider: colliderID)
            }
        }
        builtTerrains.forEach { entity, state in
            guard entity.components[Terrain3D.self] == nil else { return }
            let id = entity.id, colliderID = state.collider
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Terrain3D.self] == nil else { return }
                if let colliderID { world.removeEntity(colliderID, recursively: true) }
                owner.components.remove(Mesh3DComponent.self)
                owner.components.remove(Terrain3DRuntimeState.self)
            }
        }
    }

    private static func worldMatrix(_ entity: Entity) -> Transform3D {
        var matrix = entity.components[Transform.self]?.matrix ?? .identity
        var parentID = entity.components[RelationshipComponent.self]?.parent
        var visited: Set<Entity.ID> = [entity.id]
        while let id = parentID, visited.insert(id).inserted, let parent = entity.world?.getEntityByID(id) {
            matrix = (parent.components[Transform.self]?.matrix ?? .identity) * matrix
            parentID = parent.components[RelationshipComponent.self]?.parent
        }
        return matrix
    }
}
