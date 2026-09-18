//
//  ScriptComponentUpdateSystem.swift
//  AdaEngine
//

@_spi(Internal) import AdaECS
@_spi(Internal) import AdaInput
import AdaUtils

/// Updates attached scriptable objects and owns their explicit lifecycle.
@PlainSystem
public struct ScriptComponentUpdateSystem {
    @Res<DeltaTime>
    private var time

    @ResMut<Input>
    private var input

    @Query<Entity, ScriptableComponents>
    private var scriptableComponents

    @Commands
    private var commands

    @ScriptableObjectAccess
    private var declaredAccess

    @Local
    private var fixedTime = FixedTimestep(stepsPerSecond: 60)

    @Local
    private var activeScripts: [ObjectIdentifier: ActiveScript] = [:]

    public init(world _: World) {}

    @MainActor
    public func update(context: UpdateContext) {
        let fixedResult = fixedTime.advance(with: time.deltaTime)
        var seen: Set<ObjectIdentifier> = []

        scriptableComponents.forEach { entity, components in
            for script in components.scripts {
                update(
                    script: script,
                    entity: entity,
                    world: context.world,
                    fixedResult: fixedResult,
                    seen: &seen
                )
            }
        }

        let detachedIdentities = activeScripts.keys.filter { !seen.contains($0) }
        for identity in detachedIdentities {
            guard let active = activeScripts.removeValue(forKey: identity) else {
                continue
            }
            active.object.detach(
                context: ScriptableObjectContext(
                    entity: active.entity,
                    world: context.world,
                    commands: commands,
                    input: input,
                    deltaTime: 0
                )
            )
        }
    }

    @MainActor
    private func update(
        script: ScriptableObject,
        entity: Entity,
        world: World,
        fixedResult: FixedTimestep.AdvanceResult,
        seen: inout Set<ObjectIdentifier>
    ) {
        let identity = ObjectIdentifier(script)
        if let descriptor = ScriptableObjectRegistry.descriptor(for: script),
            !descriptor.requiredComponents.allSatisfy({ world.has($0, in: entity.id) }) {
            return
        }
        guard script.attach(to: entity) else {
            return
        }
        seen.insert(identity)
        activeScripts[identity] = ActiveScript(object: script, entity: entity)

        let updateContext = makeContext(entity: entity, world: world, deltaTime: time.deltaTime)
        script.runReadyIfNeeded(context: updateContext)
        if !input.eventsPool.isEmpty {
            script.event(input.eventsPool, context: updateContext)
        }
        script.update(context: updateContext)
        if fixedResult.isFixedTick {
            script.fixedUpdate(
                context: makeContext(
                    entity: entity,
                    world: world,
                    deltaTime: fixedResult.fixedTime
                )
            )
        }
    }

    private func makeContext(
        entity: Entity,
        world: World,
        deltaTime: AdaUtils.TimeInterval
    ) -> ScriptableObjectContext {
        ScriptableObjectContext(
            entity: entity,
            world: world,
            commands: commands,
            input: input,
            deltaTime: deltaTime
        )
    }
}

private struct ActiveScript: @unchecked Sendable {
    let object: ScriptableObject
    let entity: Entity
}
