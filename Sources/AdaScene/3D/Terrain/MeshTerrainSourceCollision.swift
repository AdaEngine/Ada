import AdaECS
import AdaGeometry
@_spi(Internal) import AdaPhysics
import AdaUtils

/// Runtime backup contains authored values and immutable shapes, never a native body handle.
struct MeshTerrainSourceCollisionBackup: Component, Sendable {
    let owner: Entity.ID
    let body: PhysicsBody3DComponent
    let revision = RID()
}

enum MeshTerrainSourceCollisionOwnership {
    static func validate(_ selected: [Entity.ID], owner: Entity, world: World) throws {
        guard selected.count <= 512, Set(selected).count == selected.count else { throw TriangleGeometryError.budgetExceeded }
        if !selected.isEmpty {
            guard owner.components[Terrain3DSource.self]?.generatesCollision == true,
                world.getResource(Physics3DWorldHolder.self) != nil else { throw TriangleGeometryError.invalidInput }
        }
        for id in selected {
            guard id != owner.id, let source = world.getEntityByID(id),
                source.components[MeshTerrainSourceCollisionBackup.self].map({ $0.owner == owner.id }) ?? true,
                source.components[PhysicsBody3DComponent.self].map({ $0.mode == .static }) ?? true,
                source.components[PhysicsBody3DComponent.self] != nil || source.components[MeshTerrainSourceCollisionBackup.self] != nil else {
                throw TriangleGeometryError.invalidInput
            }
        }
    }

    static func publish(_ selected: [Entity.ID], owner: Entity, world: World) {
        guard var state = owner.components[TerrainSourceState.self] else { return }
        let next = Set(selected)
        for id in state.meshCollisionSources.subtracting(next) {
            if let source = world.getEntityByID(id) { restore(source, owner: owner.id, world: world) }
        }
        for id in selected {
            guard let source = world.getEntityByID(id) else { continue }
            if let body = Physics3DSyncSystem.suspendImmediately(source) {
                source.components[MeshTerrainSourceCollisionBackup.self] = .init(owner: owner.id, body: body)
            }
        }
        state.meshCollisionSources = next
        owner.components[TerrainSourceState.self] = state
    }

    static func restore(_ source: Entity, owner: Entity.ID, world: World) {
        guard let backup = source.components[MeshTerrainSourceCollisionBackup.self], backup.owner == owner else { return }
        if source.components[PhysicsBody3DComponent.self] == nil {
            source.components[PhysicsBody3DComponent.self] = backup.body.authoredCopy()
            if let physics = world.getResource(Physics3DWorldHolder.self)?.world {
                Physics3DSyncSystem.initializeImmediately(source, in: physics)
            }
        }
        source.components.remove(MeshTerrainSourceCollisionBackup.self)
        if let terrain = world.getEntityByID(owner), var state = terrain.components[TerrainSourceState.self] {
            state.meshCollisionSources.remove(source.id)
            terrain.components[TerrainSourceState.self] = state
        }
    }

    static func sources(root: Entity, parts: [MeshTerrainCapturedPart], world: World) throws -> [Entity.ID] {
        var result: Set<Entity.ID> = []
        for part in parts {
            var next: Entity.ID? = part.entity, visited: Set<Entity.ID> = []
            while let id = next, visited.insert(id).inserted, let entity = world.getEntityByID(id) {
                if let body = entity.components[PhysicsBody3DComponent.self] {
                    guard body.mode == .static else { throw TriangleGeometryError.invalidInput }
                    result.insert(id)
                } else if entity.components[MeshTerrainSourceCollisionBackup.self] != nil { result.insert(id) }
                if id == root.id { break }
                next = entity.components[RelationshipComponent.self]?.parent
            }
        }
        return result.sorted()
    }
}
