import AdaECS
import AdaPhysics
import AdaTransform
import Math

/// Rechecks scripted movement after native body synchronization, before the fixed physics step.
@PlainSystem(dependencies: [.afterIfPresent(Physics3DSyncSystem.self)])
struct TerrainPhysicsReadinessSystem {
    @Query<Entity, Terrain3DSource> private var sources
    @Query<Entity, PhysicsBody3DComponent, Transform> private var bodies
    @FilterQuery<Entity, CharacterController3DComponent, Transform, Without<PhysicsBody3DComponent>> private var characters
    @Res<Physics3DWorldHolder?> private var physicsWorld
    @Res<FixedTime?> private var fixedTime
    @Commands private var commands

    init(world _: World) {}

    func update(context: UpdateContext) {
        guard physicsWorld != nil, sources.first != nil else {
            return
        }
        let bounds = TerrainPhysicsBounds.collect(bodies: bodies, characters: characters, physics: physicsWorld, deltaTime: fixedTime?.deltaTime ?? 0)
        sources.forEach { entity, source in
            let id = entity.id
            let matrix = Terrain3DSourceSystem.worldMatrix(entity)
            let interests = TerrainPhysicsInterests.project(bounds, inverse: matrix.inverse)
            let status = entity.components[Terrain3DSourceStatus.self]
            let state = entity.components[TerrainSourceState.self]
            let checksCollision = source.generatesCollision && !source.source.isEmpty && !interests.isEmpty
            var ready = true
            if checksCollision {
                ready = status?.error == nil && state?.key == TerrainSourceKey(source) && state?.matrix == matrix
                if let state, state.meshAsset != nil {
                    // Compiled mesh sections have static colliders without heightfield residency.
                    ready = ready && state.publishedSettings?.generatesCollision == true && state.tiles.values.allSatisfy { tile in
                        guard let collider = tile.collider, let child = context.world.getEntityByID(collider) else { return false }
                        return child.components[PhysicsBody3DComponent.self]?.worldBounds?.isEmpty == false
                    }
                } else if let state, let storage = state.storage, let residency = state.residency {
                    ready = ready && storage.revision == state.revision
                    if ready && (state.focus?.physics != interests || state.attempted.physicsPadding != source.physicsPadding) {
                        let declared = Set(residency.cache.manifest.heightRegions.map { TerrainRegionCoordinate(x: Int($0.x), z: Int($0.z)) })
                        let available = declared.union(residency.overrides.keys).union(storage.regionCoordinates)
                        let required = TerrainSourceResidency.physicsRegions(
                            available: available,
                            manifest: residency.cache.manifest,
                            interests: interests,
                            padding: source.physicsPadding
                        )
                        ready = required.isSubset(of: residency.visible)
                    }
                    if ready {
                        for tile in state.tiles.values {
                            guard let collider = tile.collider, let child = context.world.getEntityByID(collider),
                                child.components[PhysicsBody3DComponent.self]?.worldBounds?.isEmpty == false
                            else { ready = false; break }
                        }
                    }
                    if ready {
                        ready = state.publishedSettings?.instanceCollision == source.instanceCollision
                        if ready && state.focus?.physics != interests,
                            state.instanceCells.values.contains(where: { !$0.prepared.collisionPlacements.isEmpty }) {
                            if let required = try? TerrainSourceInstanceCollisions.requiredIDs(state: state, physics: interests, source: source) {
                                ready = required.allSatisfy { state.instanceColliders[$0] != nil }
                            } else { ready = false }
                        }
                        if ready {
                            ready = state.instanceColliders.values.allSatisfy {
                                context.world.getEntityByID($0.entity)?.components[PhysicsBody3DComponent.self]?.worldBounds?.isEmpty == false
                            }
                        }
                    }
                } else {
                    ready = false
                }
            }
            let collisionReady = ready
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Terrain3DSource.self] == source else {
                    return
                }
                Terrain3DSourceSystem.setPhysicsPending(!collisionReady, owner: id, world: world)
                if checksCollision {
                    owner.components[Terrain3DSourceStatus.self] = .init(
                        isReady: collisionReady && status?.isPreparing != true,
                        tileCount: state?.tiles.count ?? 0,
                        error: status?.error,
                        preparedTileCount: status?.preparedTileCount ?? 0,
                        pendingTileCount: status?.pendingTileCount ?? 0,
                        isPreparing: status?.isPreparing ?? false,
                        warnings: status?.warnings ?? [],
                        instanceColliderCount: state?.instanceColliders.count ?? 0
                    )
                }
            }
        }
    }
}
