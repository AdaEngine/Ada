import AdaECS

struct TerrainGenerated3D: Component, Hashable {
    let owner: Entity.ID
    let sourceBacked: Bool
}

/// Generated children outlive a nonrecursively removed owner in ordinary ECS hierarchy semantics.
/// Track their authored owner explicitly so terrain can clean only its own derived resources.
@PlainSystem(dependencies: [.after(Terrain3DSystem.self), .after(Terrain3DSourceSystem.self)])
struct TerrainGeneratedCleanup3DSystem {
    @Query<Entity, TerrainGenerated3D> private var generated
    @Query<Entity, Terrain3D> private var terrains
    @Query<Entity, Terrain3DSource> private var sources
    @Query<Entity, TerrainSourceState> private var sourceStates
    @Query<Entity, MeshTerrain3DSourceMask> private var sourceMasks
    @Query<Entity, MeshTerrainSourceCollisionBackup> private var sourceCollisions
    @Commands private var commands

    init(world _: World) {}

    func update(context _: UpdateContext) {
        guard generated.first != nil || sourceMasks.first != nil || sourceCollisions.first != nil else {
            return
        }
        var live: Set<TerrainGenerated3D> = []
        terrains.forEach { entity, _ in live.insert(.init(owner: entity.id, sourceBacked: false)) }
        sources.forEach { entity, _ in live.insert(.init(owner: entity.id, sourceBacked: true)) }
        var meshOwners: Set<Entity.ID> = []
        sourceStates.forEach { entity, state in if state.meshAsset != nil { meshOwners.insert(entity.id) } }
        sourceMasks.forEach { entity, mask in
            guard !meshOwners.contains(mask.owner) || !live.contains(.init(owner: mask.owner, sourceBacked: true)) else { return }
            let id = entity.id
            commands.queue.push { world in
                guard let source = world.getEntityByID(id), source.components[MeshTerrain3DSourceMask.self]?.revision == mask.revision else { return }
                let owner = world.getEntityByID(mask.owner)
                if owner?.components[Terrain3DSource.self] == nil || owner?.components[TerrainSourceState.self]?.meshAsset == nil {
                    source.components.remove(MeshTerrain3DSourceMask.self)
                }
            }
        }
        sourceCollisions.forEach { entity, backup in
            let id = entity.id
            commands.queue.push { world in
                guard let source = world.getEntityByID(id), source.components[MeshTerrainSourceCollisionBackup.self]?.revision == backup.revision else { return }
                let owner = world.getEntityByID(backup.owner)
                let state = owner?.components[TerrainSourceState.self]
                if owner?.components[Terrain3DSource.self] == nil || state?.meshAsset == nil || state?.publishedSettings?.generatesCollision == false {
                    MeshTerrainSourceCollisionOwnership.restore(source, owner: backup.owner, world: world)
                }
            }
        }
        generated.forEach { entity, marker in
            guard !live.contains(marker) else {
                return
            }
            let id = entity.id
            commands.queue.push { world in
                guard let child = world.getEntityByID(id), child.components[TerrainGenerated3D.self] == marker else {
                    return
                }
                let owner = world.getEntityByID(marker.owner)
                let retained = marker.sourceBacked ? owner?.components.has(Terrain3DSource.self) : owner?.components.has(Terrain3D.self)
                if retained != true { world.removeEntity(id, recursively: true) }
            }
        }
    }
}
