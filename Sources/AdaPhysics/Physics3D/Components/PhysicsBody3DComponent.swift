//
//  PhysicsBody3DComponent.swift
//  AdaEngine
//
//  Created by Codex on 7/6/26.
//

import AdaECS
import Math

/// A component that defines an entity's behavior in 3D physics simulations.
@Component
public struct PhysicsBody3DComponent: Codable {
    /// The physics body's mode, indicating how or if it moves.
    public var mode: PhysicsBodyMode

    internal var runtimeBody: Body3D?
    internal private(set) var shapes: [Shape3DResource]

    /// The physics body's material properties.
    public var material: PhysicsMaterial

    /// The physics body's mass properties.
    public var massProperties: PhysicsMassProperties

    /// Get the world position of the center of mass.
    public var worldCenter: Vector3 {
        self.runtimeBody?.getWorldCenter() ?? .zero
    }

    /// Is this body a sensor?
    public let isTrigger: Bool

    private var initialGravityScale: Float = 1
    private var initialLinearVelocity: Vector3 = .zero
    private var initialAngularVelocity: Vector3 = .zero

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
    public var linearVelocity: Vector3 {
        get {
            self.runtimeBody?.getLinearVelocity() ?? initialLinearVelocity
        }

        set {
            initialLinearVelocity = newValue
            self.runtimeBody?.setLinearVelocity(newValue)
        }
    }

    /// Angular velocity in radians per second.
    public var angularVelocity: Vector3 {
        get {
            self.runtimeBody?.getAngularVelocity() ?? initialAngularVelocity
        }

        set {
            initialAngularVelocity = newValue
            self.runtimeBody?.setAngularVelocity(newValue)
        }
    }

    public init(
        shapes: [Shape3DResource],
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
        shapes: [Shape3DResource],
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
        case shapes
        case material
        case massProperties
        case isTrigger
        case gravityScale
        case linearVelocity
        case angularVelocity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decode(PhysicsBodyMode.self, forKey: .mode)
        self.shapes = try container.decode([Shape3DResource].self, forKey: .shapes)
        self.material = try container.decode(PhysicsMaterial.self, forKey: .material)
        self.massProperties = try container.decode(PhysicsMassProperties.self, forKey: .massProperties)
        self.isTrigger = try container.decode(Bool.self, forKey: .isTrigger)
        self.initialGravityScale = try container.decodeIfPresent(Float.self, forKey: .gravityScale) ?? 1
        self.initialLinearVelocity = try container.decodeIfPresent(Vector3.self, forKey: .linearVelocity) ?? .zero
        self.initialAngularVelocity = try container.decodeIfPresent(Vector3.self, forKey: .angularVelocity) ?? .zero
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.shapes, forKey: .shapes)
        try container.encode(self.mode, forKey: .mode)
        try container.encode(self.material, forKey: .material)
        try container.encode(self.massProperties, forKey: .massProperties)
        try container.encode(self.isTrigger, forKey: .isTrigger)
        try container.encode(gravityScale, forKey: .gravityScale)
        try container.encode(linearVelocity, forKey: .linearVelocity)
        try container.encode(angularVelocity, forKey: .angularVelocity)
    }

    // MARK: - Methods

    /// Set the position and rotation of the body's origin.
    public func setTransform(position: Vector3, rotation: Quat? = nil) {
        let bodyRotation = self.runtimeBody?.getRotation() ?? .identity
        self.runtimeBody?.setTransform(position: position, rotation: rotation ?? bodyRotation)
    }

    /// Apply a force at a world point.
    public func applyForce(force: Vector3, point: Vector3, wake: Bool) {
        self.runtimeBody?.applyForce(force: force, point: point, wake: wake)
    }

    /// Apply a force to the center of mass.
    public func applyForceToCenter(_ force: Vector3, wake: Bool) {
        self.runtimeBody?.applyForceToCenter(force, wake: wake)
    }

    /// Clear all velocity.
    public func clearForces() {
        self.runtimeBody?.setLinearVelocity(.zero)
        self.runtimeBody?.setAngularVelocity(.zero)
    }

    /// Apply an impulse at a point.
    public func applyLinearImpulse(_ impulse: Vector3, point: Vector3, wake: Bool) {
        self.runtimeBody?.applyLinearImpulse(impulse, point: point, wake: wake)
    }

    /// Apply torque.
    public func applyTorque(_ torque: Vector3, wake: Bool) {
        self.runtimeBody?.applyTorque(torque, wake: wake)
    }
}
