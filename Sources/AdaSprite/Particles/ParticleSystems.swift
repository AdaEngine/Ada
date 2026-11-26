import AdaAssets
import AdaECS
import AdaRender
import AdaTransform
import AdaUtils
import Math

@PlainSystem(dependencies: [.after(ChildTransformSystem.self)])
struct ParticleSimulationSystem {
    @Query<Entity, Ref<ParticleEmitter>, GlobalTransform> private var emitters
    @Res<DeltaTime> private var time
    @Commands private var commands

    init(world _: World) {}

    func update(context _: UpdateContext) {
        emitters.forEach { entity, emitter, transform in
            guard let effect = emitter.effect?.asset else {
                emitter.simulation = nil
                return
            }
            if emitter.simulation?.descriptor != effect.descriptor || emitter.appliedRestartCount != emitter.restartCount {
                emitter.simulation = try? ParticleSimulation(effect.descriptor)
                emitter.appliedRestartCount = emitter.restartCount
                // Particles can travel beyond the owner's origin bounds; retain camera/layer visibility.
                commands.entity(entity.id).insert(NoFrustumCulling())
            }
            if !emitter.isPaused {
                emitter.simulation?.advance(by: Double(time.deltaTime), transform: transform.matrix, emitting: emitter.isEmitting)
            }
        }
    }
}

/// Kept separate from tilemap contributions, whose extraction clears its own sprite buffer.
package struct ExtractedParticleSprites: Resource {
    package var sprites: [Entity.ID: ExtractedSprite]

    package init(sprites: [Entity.ID: ExtractedSprite] = [:]) {
        self.sprites = sprites
    }
}

@PlainSystem
struct ExtractParticleSpritesSystem {
    @Extract<Query<Entity, ParticleEmitter, GlobalTransform, Visibility>> private var emitters
    @Extract<Query<RelationshipComponent>> private var hierarchy
    @ResMut<ExtractedParticleSprites> private var extracted

    init(world _: World) {}

    func update(context _: UpdateContext) {
        _ = hierarchy.wrappedValue
        extracted.sprites.removeAll(keepingCapacity: true)
        // Entities use positive IDs; tilemap render IDs start at Int.min / Int.min/2.
        var renderID = -1
        emitters.wrappedValue.forEach { entity, emitter, transform, visibility in
            guard visibility.isVisible(inHierarchyOf: entity), let effect = emitter.effect?.asset else {
                return
            }
            emitter.simulation?.forEachParticle(transform: transform.matrix) { sample in
                let texture = effect.textures.indices.contains(sample.emitterIndex) ? effect.textures[sample.emitterIndex]?.asset : nil
                extracted.sprites[renderID] = ExtractedSprite(
                    entityId: renderID,
                    texture: texture,
                    size: Size(width: sample.size, height: sample.size),
                    flipX: false,
                    flipY: false,
                    tintColor: sample.color,
                    transform: Transform(matrix: sample.transform),
                    worldTransform: sample.transform,
                    visibilityEntityId: entity.id
                )
                renderID -= 1
            }
        }
    }
}
