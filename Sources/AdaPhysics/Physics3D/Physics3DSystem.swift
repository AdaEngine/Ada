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
    _ performance: Res<PhysicsPerformanceMetrics?>,
    _ fixedTime: Res<FixedTime>
) {
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
            if physicsBody.runtimeBody == nil {
                var def = b3DefaultBodyDef()
                def.position = transform.position.b3Vec
                def.rotation = transform.rotation.b3Quat
                def.type = physicsBody.mode.b3Type
                def.gravityScale = physicsBody.gravityScale
                def.linearVelocity = physicsBody.linearVelocity.b3Vec
                def.angularVelocity = physicsBody.angularVelocity.b3Vec

                let body = world.createBody(with: def, for: entity)
                physicsBody.runtimeBody = body

                for shapeResource in physicsBody.wrappedValue.shapes {
                    var shapeDef = b3DefaultShapeDef()
                    shapeDef.density = physicsBody.material.density
                    shapeDef.baseMaterial.restitution = physicsBody.material.restitution
                    shapeDef.baseMaterial.friction = physicsBody.material.friction

                    if physicsBody.wrappedValue.isTrigger {
                        shapeDef.isSensor = true
                    }

                    body.appendShape(
                        shapeResource,
                        shapeDef: shapeDef
                    )
                }

                var massData = body.massData
                massData.mass = physicsBody.massProperties.mass
                body.massData = massData

                commands.entity(entity.id).insert(PhysicsBody3DInitialized())
            }
        }
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
