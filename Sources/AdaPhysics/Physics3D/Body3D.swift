//
//  Body3D.swift
//  AdaEngine
//
//  Created by Codex on 7/6/26.
//

import AdaECS
import AdaTransform
import box3d
import Math

/// This class is used to hold a box3d body reference.
public final class Body3D: @unchecked Sendable {
    weak var world: PhysicsWorld3D?
    weak var entity: Entity?

    let bodyId: b3BodyId

    internal init(world: consuming PhysicsWorld3D, bodyId: consuming b3BodyId, entity: consuming Entity) {
        self.world = world
        self.bodyId = bodyId
        self.entity = entity
    }

    deinit {
        if world != nil, b3Body_IsValid(bodyId) {
            b3DestroyBody(bodyId)
        }
    }

    @discardableResult
    func appendShape(
        _ shapeResource: Shape3DResource,
        shapeDef: b3ShapeDef
    ) -> BoxShape3D {
        let shapeId = BoxShape3D.makeShape(
            for: shapeResource,
            shapeDef: shapeDef,
            bodyId: bodyId
        )
        return BoxShape3D(shape: shapeId)
    }

    var gravityScale: Float {
        get {
            b3Body_GetGravityScale(bodyId)
        }

        set {
            b3Body_SetGravityScale(bodyId, newValue)
        }
    }

    var massData: b3MassData {
        get { b3Body_GetMassData(bodyId) }
        set { b3Body_SetMassData(bodyId, newValue) }
    }

    func getPosition() -> Vector3 {
        b3Body_GetPosition(bodyId).asVector3
    }

    func getRotation() -> Quat {
        b3Body_GetRotation(bodyId).asQuat
    }

    func getLinearVelocity() -> Vector3 {
        b3Body_GetLinearVelocity(bodyId).asVector3
    }

    func getAngularVelocity() -> Vector3 {
        b3Body_GetAngularVelocity(bodyId).asVector3
    }

    func getWorldCenter() -> Vector3 {
        b3Body_GetWorldCenterOfMass(bodyId).asVector3
    }

    func setTransform(position: Vector3, rotation: Quat) {
        b3Body_SetTransform(bodyId, position.b3Vec, rotation.b3Quat)
    }

    /// Set the linear velocity of the center of mass.
    func setLinearVelocity(_ vector: Vector3) {
        b3Body_SetLinearVelocity(bodyId, vector.b3Vec)
    }

    /// Set the angular velocity in radians per second.
    func setAngularVelocity(_ vector: Vector3) {
        b3Body_SetAngularVelocity(bodyId, vector.b3Vec)
    }

    /// Apply a force at a world point. If the force is not applied at the center of mass, it will generate torque.
    func applyForce(force: Vector3, point: Vector3, wake: Bool) {
        b3Body_ApplyForce(bodyId, force.b3Vec, point.b3Vec, wake)
    }

    /// Apply a force to the center of mass. This wakes up the body.
    func applyForceToCenter(_ force: Vector3, wake: Bool) {
        b3Body_ApplyForceToCenter(bodyId, force.b3Vec, wake)
    }

    /// Apply an impulse at a point. This immediately modifies the velocity.
    func applyLinearImpulse(_ impulse: Vector3, point: Vector3, wake: Bool) {
        b3Body_ApplyLinearImpulse(bodyId, impulse.b3Vec, point.b3Vec, wake)
    }

    /// Apply a torque. This affects angular velocity without changing center of mass velocity.
    func applyTorque(_ torque: Vector3, wake: Bool) {
        b3Body_ApplyTorque(bodyId, torque.b3Vec, wake)
    }
}

final class BoxShape3D {
    private let shape: b3ShapeId

    init(shape: consuming b3ShapeId) {
        self.shape = shape
    }

    @inline(__always)
    var bodyId: b3BodyId {
        b3Shape_GetBody(shape)
    }

    @inline(__always)
    var isValid: Bool {
        b3Shape_IsValid(shape)
    }

    @inline(__always)
    var isSensor: Bool {
        b3Shape_IsSensor(shape)
    }

    var body: Body3D? {
        guard let ptr = b3Body_GetUserData(bodyId) else {
            return nil
        }

        return Unmanaged<Body3D>.fromOpaque(ptr).takeUnretainedValue()
    }

    var filter: b3Filter {
        get {
            b3Shape_GetFilter(shape)
        }

        set {
            b3Shape_SetFilter(shape, newValue, true)
        }
    }

    static func makeShape(
        for shape: Shape3DResource,
        shapeDef: b3ShapeDef,
        bodyId: b3BodyId
    ) -> b3ShapeId {
        switch shape.fixture {
        case let .box(shape):
            var hull = b3MakeBoxHull(
                shape.halfExtents.x,
                shape.halfExtents.y,
                shape.halfExtents.z
            )
            return withUnsafePointer(to: shapeDef) { shapeDefPtr in
                withUnsafePointer(to: &hull.base) { hullPtr in
                    b3CreateHullShape(bodyId, shapeDefPtr, hullPtr)
                }
            }
        case let .sphere(shape):
            var sphere = b3Sphere(center: shape.center.b3Vec, radius: shape.radius)
            return withUnsafePointer(to: shapeDef) { shapeDefPtr in
                withUnsafePointer(to: &sphere) { spherePtr in
                    b3CreateSphereShape(bodyId, shapeDefPtr, spherePtr)
                }
            }
        }
    }
}
