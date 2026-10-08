//
//  Physics2DSystem.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/8/22.
//

import AdaECS
import AdaTransform
import AdaUtils
import box2d
import Math

@MainActor
@System
public func Physics2DUpdate(
    _ physicsWorld: Res<Physics2DWorldHolder>,
    _ performance: Res<PhysicsPerformanceMetrics?>,
    _ fixedTime: Res<FixedTime>
) {
    let deltaTime = fixedTime.deltaTime
    let world = physicsWorld.world
    world.updateSimulation(deltaTime)
    performance.wrappedValue?.recordPerformance(from: world)
    world.processContacts()
    world.processSensors()
}

extension PhysicsPerformanceMetrics {
    func recordPerformance(from world: PhysicsWorld2D) {
        world.recordPerformance(into: self)
    }
}

// - TODO: (Vlad) Runtime update shape resource

/// A system for simulate and update physics bodies on the scene.
@PlainSystem
public struct Physics2DSyncSystem: Sendable {
    @Query<Entity, Ref<PhysicsBody2DComponent>, Ref<Transform>>
    private var physicsBodyQuery

    @Query<Entity, Ref<Collision2DComponent>, Ref<Transform>>
    private var collisionQuery

    @Query<Entity, Ref<PhysicsJoint2DComponent>, Ref<Transform>>
    private var jointsQuery

    @Res<Physics2DWorldHolder>
    private var physicsWorld

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        self.syncPhysicsBodyEntities(in: physicsWorld.world)
        self.syncCollisionEntities(in: physicsWorld.world)
    }

    // MARK: - Private

    private func syncPhysicsBodyEntities(in world: PhysicsWorld2D) {
        self.physicsBodyQuery.forEach { entity, physicsBody, transform in
            if let body = physicsBody.runtimeBody {
                if physicsBody.mode == .static {
                    body.setTransform(
                        position: transform.position.xy,
                        angle: transform.rotation.angle2D
                    )
                }

                applyMassProperties(physicsBody.massProperties, fixedRotation: physicsBody.fixedRotation, to: body)
            } else {
                var def = unsafe b2DefaultBodyDef()
                unsafe def.fixedRotation = physicsBody.fixedRotation
                unsafe def.position = transform.position.xy.b2Vec
                unsafe def.type = physicsBody.mode.b2Type
                unsafe def.gravityScale = physicsBody.gravityScale
                unsafe def.linearVelocity = physicsBody.linearVelocity.b2Vec
                unsafe def.angularVelocity = physicsBody.angularVelocity

                let body = unsafe world.createBody(with: def, for: entity)
                physicsBody.runtimeBody = body

                for shapeResource in physicsBody.wrappedValue.shapes {
                    var shapeDef = unsafe b2DefaultShapeDef()
                    unsafe shapeDef.density = physicsBody.material.density
                    unsafe shapeDef.restitution = physicsBody.material.restitution
                    unsafe shapeDef.friction = physicsBody.material.friction
                    unsafe shapeDef.filter = physicsBody.filter.b2Filter

                    if physicsBody.wrappedValue.isTrigger {
                        unsafe shapeDef.isSensor = true
                    }

                    if let debugColor = physicsBody.debugColor {
                        unsafe shapeDef.customColor = UInt32(debugColor.toHex)
                    }

                    unsafe body.appendShape(
                        shapeResource,
                        transform: transform.wrappedValue,
                        shapeDef: shapeDef
                    )
                }

                applyMassProperties(physicsBody.massProperties, fixedRotation: physicsBody.fixedRotation, to: body)
            }

            if let shapes = physicsBody.runtimeBody?.getShapes() {
                let collisionFilter = physicsBody.filter

                for shape in shapes {
                    let filterData = shape.filter

                    if !(filterData.categoryBits == collisionFilter.categoryBitMask.rawValue
                        && filterData.maskBits == collisionFilter.collisionBitMask.rawValue) {
                        shape.filter = collisionFilter.b2Filter
                    }
                }
            }
        }
    }

    private func applyMassProperties(_ properties: PhysicsMassProperties, fixedRotation: Bool, to body: Body2D) {
        var data = body.massData
        data.mass = properties.mass
        if fixedRotation {
            data.rotationalInertia = 0
        } else if properties.inertia.z > 0 {
            data.rotationalInertia = properties.inertia.z
        }
        body.massData = data
    }

    private func syncCollisionEntities(in world: PhysicsWorld2D) {
        collisionQuery.forEach { entity, collisionBody, transform in
            if let body = collisionBody.runtimeBody {
                if body.getPosition() != transform.position.xy {
                    body.setTransform(
                        position: transform.position.xy,
                        angle: transform.rotation.angle2D
                    )
                }
            } else {
                var def = unsafe b2DefaultBodyDef()
                unsafe def.position = transform.position.xy.b2Vec
                unsafe def.type = b2_staticBody

                let body = unsafe world.createBody(with: def, for: entity)
                collisionBody.runtimeBody = body

                for shapeResource in collisionBody.wrappedValue.shapes {
                    var shapeDef = unsafe b2DefaultShapeDef()
                    unsafe shapeDef.density = 1
                    if let debugColor = collisionBody.debugColor {
                        unsafe shapeDef.customColor = UInt32(debugColor.toHex)
                    }
                    unsafe shapeDef.filter = collisionBody.filter.b2Filter
                    if case .trigger = collisionBody.mode {
                        unsafe shapeDef.isSensor = true
                    }
                    unsafe body.appendShape(
                        shapeResource,
                        transform: transform.wrappedValue,
                        shapeDef: shapeDef
                    )
                }
            }

            if let shapes = collisionBody.runtimeBody?.getShapes() {
                let collisionFilter = collisionBody.filter

                for shape in shapes {
                    let filterData = shape.filter

                    if !(filterData.categoryBits == collisionFilter.categoryBitMask.rawValue && filterData.maskBits == collisionFilter.collisionBitMask.rawValue) {
                        shape.filter = collisionFilter.b2Filter
                    }
                }
            }
        }
    }
}

/// A system for writing back simulated 2D physics state into scene components.
@PlainSystem
public struct Physics2DWritebackSystem: Sendable {
    @Res<Physics2DWorldHolder>
    private var physicsWorld

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        physicsWorld.world.forEachMovedBody { entity, position, rotation in
            guard var transform = entity.components[Transform.self] else {
                return
            }

            guard
                transform.position.x != position.x || transform.position.y != position.y || transform.rotation != rotation
            else {
                return
            }

            transform.position.x = position.x
            transform.position.y = position.y
            transform.rotation = rotation
            entity.components[Transform.self] = transform
        }
    }
}

extension CollisionFilter {
    var b2Filter: b2Filter {
        var filter = b2DefaultFilter()
        filter.categoryBits = categoryBitMask.rawValue
        filter.maskBits = collisionBitMask.rawValue
        return filter
    }
}

extension Quat {
    var angle2D: Angle {
        let rads = Math.atan2(
            2 * (self.w * self.z + self.x * self.y),
            1 - 2 * (self.y * self.y + self.z * self.z)
        )
        return Angle.radians(rads)
    }
}
