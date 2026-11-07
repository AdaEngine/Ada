//
//  Physics3DSystem.swift
//  AdaEngine
//
//  Created by Codex on 7/6/26.
//

import AdaECS
import AdaTransform
import box3d
import Math

@Component
struct PhysicsBody3DInitialized: Sendable {}

@MainActor
@System
public func Physics3DUpdate(
    _ physicsWorld: Res<Physics3DWorldHolder>,
    _ gate: Res<PhysicsSimulationGate3D?>,
    _ performance: Res<PhysicsPerformanceMetrics?>,
    _ fixedTime: Res<FixedTime>
) {
    guard gate.wrappedValue?.isReady != false else {
        return
    }
    let deltaTime = fixedTime.deltaTime
    let world = physicsWorld.world
    world.updateSimulation(deltaTime)
    performance.wrappedValue?.recordPerformance(from: world)
}

extension PhysicsPerformanceMetrics {
    func recordPerformance(from world: PhysicsWorld3D) {
        world.recordPerformance(into: self)
    }
}

/// A system for simulating and updating physics bodies on the scene.
@PlainSystem
public struct Physics3DSyncSystem: Sendable {
    @FilterQuery<
        Entity,
        Ref<PhysicsBody3DComponent>,
        Transform,
        Without<PhysicsBody3DInitialized>
    >
    private var physicsBodyQuery

    @Res<Physics3DWorldHolder>
    private var physicsWorld

    @Commands
    private var commands

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        self.syncPhysicsBodyEntities(in: physicsWorld.world)
    }

    // MARK: - Private

    private func syncPhysicsBodyEntities(in world: PhysicsWorld3D) {
        self.physicsBodyQuery.forEach { entity, physicsBody, transform in
            guard physicsBody.runtimeBody == nil else {
                return
            }
            var component = physicsBody.wrappedValue
            Self.initialize(&component, transform: transform, entity: entity, world: world)
            physicsBody.wrappedValue = component
            commands.entity(entity.id).insert(PhysicsBody3DInitialized())
        }
    }

    /// Initializes a prepared entity's native body before a coherent scene generation becomes ready.
    /// Call only in the serialized world-mutation phase; this method does not step simulation.
    @_spi(Internal)
    public static func initializeImmediately(_ entity: Entity, in world: PhysicsWorld3D) {
        guard var component = entity.components[PhysicsBody3DComponent.self],
            let transform = entity.components[Transform.self]
        else { return }
        if component.runtimeBody == nil {
            initialize(&component, transform: transform, entity: entity, world: world)
            entity.components[PhysicsBody3DComponent.self] = component
        }
        entity.components[PhysicsBody3DInitialized.self] = .init()
    }

    /// Removes a body's native collision and initialization marker at a serialized world boundary.
    /// The returned value owns only authored settings and immutable shape resources.
    @_spi(Internal)
    public static func suspendImmediately(_ entity: Entity) -> PhysicsBody3DComponent? {
        guard let component = entity.components[PhysicsBody3DComponent.self] else { return nil }
        let authored = component.authoredCopy()
        component.runtimeBody?.destroyImmediately()
        entity.components.remove(PhysicsBody3DComponent.self)
        entity.components.remove(PhysicsBody3DInitialized.self)
        return authored
    }

    private static func initialize(_ component: inout PhysicsBody3DComponent, transform: Transform, entity: Entity, world: PhysicsWorld3D) {
        var def = b3DefaultBodyDef()
        def.position = transform.position.b3Vec
        def.rotation = transform.rotation.b3Quat
        def.type = component.mode.b3Type
        def.gravityScale = component.gravityScale
        def.linearVelocity = component.linearVelocity.b3Vec
        def.angularVelocity = component.angularVelocity.b3Vec

        let body = world.createBody(with: def, for: entity)
        component.runtimeBody = body
        for shapeResource in component.shapes {
            var shapeDef = b3DefaultShapeDef()
            shapeDef.density = component.material.density
            shapeDef.baseMaterial.restitution = component.material.restitution
            shapeDef.baseMaterial.friction = component.material.friction
            if component.isTrigger { shapeDef.isSensor = true }
            body.appendShape(shapeResource, shapeDef: shapeDef)
        }
        var massData = body.massData
        massData.mass = component.massProperties.mass
        body.massData = massData
    }
}

/// A system for writing back simulated 3D physics state into scene components.
@PlainSystem
public struct Physics3DWritebackSystem: Sendable {
    @Res<Physics3DWorldHolder>
    private var physicsWorld

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        physicsWorld.world.forEachMovedBody { entity, position, rotation in
            guard var transform = entity.components[Transform.self] else {
                return
            }

            guard transform.position != position || transform.rotation != rotation else {
                return
            }

            transform.position = position
            transform.rotation = rotation
            entity.components[Transform.self] = transform
        }
    }
}
