//
//  Body2D.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/19/23.
//

import AdaECS
import AdaTransform
import box2d
import Math

/// This class is used to hold a box2d body reference.
public final class Body2D: @unchecked Sendable {
    weak var world: PhysicsWorld2D?
    weak var entity: Entity?

    let bodyId: b2BodyId

    internal init(world: consuming PhysicsWorld2D, bodyId: b2BodyId, entity: consuming Entity) {
        self.world = world
        self.bodyId = bodyId
        self.entity = entity
    }

    deinit {
        world?.destroyBody(self)
    }

    @discardableResult
    func appendShape(
        _ shapeResource: Shape2DResource,
        transform: Transform,
        shapeDef: b2ShapeDef
    ) -> BoxShape2D {
        let shapeId = unsafe BoxShape2D.makeShape(
            for: shapeResource,
            transform: transform,
            shapeDef: shapeDef,
            bodyId: bodyId
        )
        return BoxShape2D(shape: shapeId)
    }

    var shapesCount: Int32 {
        b2Body_GetShapeCount(bodyId)
    }

    func getShapes() -> [BoxShape2D] {
        let shapes = UnsafeMutablePointer<b2ShapeId>.allocate(capacity: Int(shapesCount))
        unsafe b2Body_GetShapes(bodyId, shapes, shapesCount)
        return unsafe Array(UnsafeBufferPointer(start: shapes, count: Int(shapesCount)))
            .map {
                BoxShape2D(shape: $0)
            }
    }

    var gravityScale: Float {
        get {
            b2Body_GetGravityScale(bodyId)
        }
        set {
            b2Body_SetGravityScale(bodyId, newValue)
        }
    }

    var massData: b2MassData {
        get { b2Body_GetMassData(bodyId) }
        set { b2Body_SetMassData(bodyId, newValue) }
    }

    func getPosition() -> Vector2 {
        b2Body_GetPosition(bodyId).asVector2
    }

    func getAngle() -> Angle {
        Angle.radians(
            b2Rot_GetAngle(b2Body_GetRotation(bodyId))
        )
    }

    func getLinearVelocity() -> Vector2 {
        b2Body_GetLinearVelocity(bodyId).asVector2
    }

    func getWorldCenter() -> Vector2 {
        b2Body_GetWorldCenterOfMass(bodyId).asVector2
    }

    func setTransform(position: Vector2, angle: Angle) {
        b2Body_SetTransform(bodyId, position.b2Vec, b2MakeRot(angle.radians))
    }

    /// Set the linear velocity of the center of mass.
    func setLinearVelocity(_ vector: Vector2) {
        b2Body_SetLinearVelocity(bodyId, vector.b2Vec)
    }

    /// Apply a force at a world point. If the force is not applied at the center of mass, it will generate a torque and affect the angular velocity. This wakes up the body.
    func applyForce(force: Vector2, point: Vector2, wake: Bool) {
        b2Body_ApplyForce(bodyId, force.b2Vec, point.b2Vec, wake)
    }

    /// Apply a force to the center of mass. This wakes up the body.
    func applyForceToCenter(_ force: Vector2, wake: Bool) {
        b2Body_ApplyForceToCenter(bodyId, force.b2Vec, wake)
    }

    /// Apply an impulse at a point. This immediately modifies the velocity.
    /// It also modifies the angular velocity if the point of application is not at the center of mass. This wakes up the body.
    func applyLinearImpulse(_ impulse: Vector2, point: Vector2, wake: Bool) {
        b2Body_ApplyLinearImpulse(bodyId, impulse.b2Vec, point.b2Vec, wake)
    }

    /// Apply a torque. This affects the angular velocity without affecting the linear velocity of the center of mass. This wakes up the body.
    func applyTorque(_ torque: Float, wake: Bool) {
        b2Body_ApplyTorque(bodyId, torque, wake)
    }

    /// Get the world linear velocity of a world point attached to this body.
    /// - Parameter worldPoint: point in world coordinates.
    /// - Returns: The world velocity of a point or zero if entity not attached to Physics2DWorld.

    func getLinearVelocityFromWorldPoint(_ worldPoint: Vector2) -> Vector2 {
        return b2Body_GetWorldPointVelocity(bodyId, worldPoint.b2Vec).asVector2
    }

    /// Get the world velocity of a local point.
    /// - Parameter localPoint: point in local coordinates.
    /// - Returns: The world velocity of a point or zero if entity not attached to Physics2DWorld.
    func getLinearVelocityFromLocalPoint(_ localPoint: Vector2) -> Vector2 {
        return b2Body_GetLocalPointVelocity(bodyId, localPoint.b2Vec).asVector2
    }

    func setAngularVelocity(_ velocity: Float) {
        b2Body_SetAngularVelocity(bodyId, velocity)
    }

    func getAngularVelocity() -> Float {
        b2Body_GetAngularVelocity(bodyId)
    }
}

final class BoxShape2D {
    private let shape: b2ShapeId

    init(shape: consuming b2ShapeId) {
        self.shape = shape
    }

    @inline(__always)
    var bodyId: b2BodyId {
        b2Shape_GetBody(shape)
    }

    @inline(__always)
    var isValid: Bool {
        b2Shape_IsValid(shape)
    }

    @inline(__always)
    var isSensor: Bool {
        b2Shape_IsSensor(shape)
    }

    var body: Body2D? {
        guard let ptr = unsafe b2Body_GetUserData(bodyId) else {
            return nil
        }

        return unsafe Unmanaged<Body2D>.fromOpaque(ptr).takeUnretainedValue()
    }

    var filter: b2Filter {
        get {
            b2Shape_GetFilter(shape)
        }

        set {
            b2Shape_SetFilter(shape, newValue)
        }
    }

    var type: b2ShapeType {
        b2Shape_GetType(shape)
    }

    func getMaterial() -> Int32 {
        b2Shape_GetMaterial(shape)
    }

    func setMaterial(_ material: Int32) {
        return b2Shape_SetMaterial(shape, material)
    }

    static func makeShape(
        for shape: Shape2DResource,
        transform: Transform,
        shapeDef: b2ShapeDef,
        bodyId: b2BodyId
    ) -> b2ShapeId {
        switch shape.fixture {
        case let .polygon(shape):
            var hull = unsafe shape.verticies.withUnsafeBytes { ptr in
                let baseAddress = unsafe ptr.assumingMemoryBound(to: b2Vec2.self).baseAddress
                return unsafe b2ComputeHull(baseAddress, Int32(shape.verticies.count))
            }

            let polygon = unsafe b2MakeOffsetPolygon(&hull, shape.offset.b2Vec, b2Rot_identity)
            return unsafe withUnsafePointer(to: shapeDef) { shapeDefPtr in
                unsafe withUnsafePointer(to: polygon) { polygonPtr in
                    unsafe b2CreatePolygonShape(bodyId, shapeDefPtr, polygonPtr)
                }
            }
        case let .circle(shape):
            var circle = b2Circle(center: Vector2.zero.b2Vec, radius: shape.radius * transform.scale.x)
            return unsafe withUnsafePointer(to: shapeDef) { shapeDefPtr in
                unsafe b2CreateCircleShape(bodyId, shapeDefPtr, &circle)
            }
        case let .box(shape):
            let polygon = b2MakeBox(
                transform.scale.x * shape.halfWidth,
                transform.scale.y * shape.halfHeight
            )

            return unsafe withUnsafePointer(to: shapeDef) { shapeDefPtr in
                unsafe withUnsafePointer(to: polygon) { polygonPtr in
                    unsafe b2CreatePolygonShape(bodyId, shapeDefPtr, polygonPtr)
                }
            }
        }
    }
}
