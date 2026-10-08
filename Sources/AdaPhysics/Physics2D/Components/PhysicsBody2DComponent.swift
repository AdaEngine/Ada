//
//  PhysicsBody2DComponent.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

import AdaECS
import AdaUtils
import Math

/// A component that defines an entity’s behavior in physics body simulations.
@Component
public struct PhysicsBody2DComponent: Codable {
    /// The physics body’s mode, indicating how or if it moves.
    public var mode: PhysicsBodyMode

    /// The physics body's filter.
    public var filter: CollisionFilter = CollisionFilter()

    internal var runtimeBody: Body2D?
    internal private(set) var shapes: [Shape2DResource]

    /// The physics body’s material properties, like friction.
    public var material: PhysicsMaterial

    /// The physics body’s mass properties, like inertia and center of mass.
    public var massProperties: PhysicsMassProperties

    /// Get the world position of the center of mass.
    /// - Returns: World position of the center of mass or zero if entity not connected to physics world.
    public var worldCenter: Vector2 {
        self.runtimeBody?.getWorldCenter() ?? .zero
    }

    /// Should this body be prevented from rotating? Useful for characters.
    public var fixedRotation: Bool = false

    /// Custom debug color.
    public var debugColor: Color?

    /// Is this body a sensor?
    public let isTrigger: Bool

    private var initialGravityScale: Float = 1
    private var initialLinearVelocity: Vector2 = .zero
    private var initialAngularVelocity: Float = 0

    public var gravityScale: Float {
        get {
            runtimeBody?.gravityScale ?? initialGravityScale
        }

        set {
            initialGravityScale = newValue
            runtimeBody?.gravityScale = newValue
        }
    }

    /// Linear velocity of the center of mass.
    /// Before simulation starts, reads and writes the initial velocity used when the body is created.
    public var linearVelocity: Vector2 {
        get {
            self.runtimeBody?.getLinearVelocity() ?? initialLinearVelocity
        }

        set {
            initialLinearVelocity = newValue
            self.runtimeBody?.setLinearVelocity(newValue)
        }
    }

    /// Set the angular velocity of a body in radians per second
    public var angularVelocity: Float {
        get {
            self.runtimeBody?.getAngularVelocity() ?? initialAngularVelocity
        }

        set {
            initialAngularVelocity = newValue
            self.runtimeBody?.setAngularVelocity(newValue)
        }
    }

    public init(
        shapes: [Shape2DResource],
        massProperties: PhysicsMassProperties,
        material: PhysicsMaterial? = nil,
        mode: PhysicsBodyMode = .dynamic,
        isTrigger: Bool = false
    ) {
        self.mode = mode
        self.shapes = shapes
        self.massProperties = massProperties
        self.material = material ?? .default
        self.isTrigger = isTrigger
    }

    public init(
        shapes: [Shape2DResource],
        mass: Float = 0,
        material: PhysicsMaterial? = nil,
        mode: PhysicsBodyMode = .dynamic,
        isTrigger: Bool = false
    ) {
        self.mode = mode
        self.shapes = shapes
        self.massProperties = PhysicsMassProperties(mass: mass, inertia: .zero)
        self.material = material ?? .default
        self.isTrigger = isTrigger
    }

    // MARK: - Codable

    enum CodingKeys: CodingKey {
        case mode
        case filter
        case shapes
        case material
        case massProperties
        case isTrigger
        case fixedRotation
        case debugColor
        case gravityScale
        case linearVelocity
        case angularVelocity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.filter = try container.decode(CollisionFilter.self, forKey: .filter)
        self.mode = try container.decode(PhysicsBodyMode.self, forKey: .mode)
        self.shapes = try container.decode([Shape2DResource].self, forKey: .shapes)
        self.material = try container.decode(PhysicsMaterial.self, forKey: .material)
        self.massProperties = try container.decode(PhysicsMassProperties.self, forKey: .massProperties)
        self.isTrigger = try container.decode(Bool.self, forKey: .isTrigger)
        self.fixedRotation = try container.decodeIfPresent(Bool.self, forKey: .fixedRotation) ?? false
        self.debugColor = try container.decodeIfPresent(Color.self, forKey: .debugColor)
        self.initialGravityScale = try container.decodeIfPresent(Float.self, forKey: .gravityScale) ?? 1
        self.initialLinearVelocity = try container.decodeIfPresent(Vector2.self, forKey: .linearVelocity) ?? .zero
        self.initialAngularVelocity = try container.decodeIfPresent(Float.self, forKey: .angularVelocity) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.shapes, forKey: .shapes)
        try container.encode(self.mode, forKey: .mode)
        try container.encode(self.filter, forKey: .filter)
        try container.encode(self.material, forKey: .material)
        try container.encode(self.massProperties, forKey: .massProperties)
        try container.encode(self.isTrigger, forKey: .isTrigger)
        try container.encode(self.fixedRotation, forKey: .fixedRotation)
        try container.encodeIfPresent(self.debugColor, forKey: .debugColor)
        try container.encode(self.gravityScale, forKey: .gravityScale)
        try container.encode(self.linearVelocity, forKey: .linearVelocity)
        try container.encode(self.angularVelocity, forKey: .angularVelocity)
    }

    // MARK: - Methods

    /// Set the position of the body’s origin and rotation. Manipulating a body’s transform may cause non-physical behavior.
    /// - Note: Contacts are updated on the next call to of Physics2DWorld.
    public func setPosition(_ position: Vector2, angle: Angle? = nil) {
        let bodyAngle = self.runtimeBody?.getAngle() ?? 0
        self.runtimeBody?.setTransform(position: position, angle: angle ?? bodyAngle)
    }

    /// Apply a force at a world point. If the force is not applied at the center of mass, it will generate a torque and affect the angular velocity. This wakes up the body.
    public func applyForce(force: Vector2, point: Vector2, wake: Bool) {
        self.runtimeBody?.applyForce(force: force, point: point, wake: wake)
    }

    /// Apply a force to the center of mass. This wakes up the body.
    public func applyForceToCenter(_ force: Vector2, wake: Bool) {
        self.runtimeBody?.applyForceToCenter(force, wake: wake)
    }

    /// Clear all forces. This will zero out the forces and torques.
    public func clearForces() {
        self.runtimeBody?.setLinearVelocity(.zero)
        self.runtimeBody?.setAngularVelocity(0)
    }

    /// Apply an impulse at a point. This immediately modifies the velocity.
    /// It also modifies the angular velocity if the point of application is not at the center of mass. This wakes up the body.
    public func applyLinearImpulse(_ impulse: Vector2, point: Vector2, wake: Bool) {
        self.runtimeBody?.applyLinearImpulse(impulse, point: point, wake: wake)
    }

    /// Apply a torque. This affects the angular velocity without affecting the linear velocity of the center of mass. This wakes up the body.
    public func applyTorque(_ torque: Float, wake: Bool) {
        self.runtimeBody?.applyTorque(torque, wake: wake)
    }

    /// Get the world linear velocity of a world point attached to this body.
    /// - Parameter worldPoint: point in world coordinates.
    /// - Returns: The world velocity of a point or zero if entity not attached to Physics2DWorld.
    public func getLinearVelocityFromWorldPoint(_ worldPoint: Vector2) -> Vector2 {
        self.runtimeBody?.getLinearVelocityFromWorldPoint(worldPoint) ?? .zero
    }

    /// Get the world velocity of a local point.
    /// - Parameter localPoint: point in local coordinates.
    /// - Returns: The world velocity of a point or zero if entity not attached to Physics2DWorld.
    public func getLinearVelocityFromLocalPoint(_ localPoint: Vector2) -> Vector2 {
        self.runtimeBody?.getLinearVelocityFromLocalPoint(localPoint) ?? .zero
    }
}
