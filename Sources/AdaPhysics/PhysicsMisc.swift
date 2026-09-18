//
//  PhysicsMisc.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

/// The ways that a physics body can move in response to physical forces.
@frozen public enum PhysicsBodyMode: Codable, Sendable {
    /// Zero mass, zero velocity, may be manually moved
    case `static`
    /// Positive mass, non-zero velocity determined by forces, moved by solver
    case `dynamic`
    /// Zero mass, non-zero velocity set by user, moved by solver
    case kinematic
}

/// A set of masks that determine whether entities can collide during simulations.
public struct CollisionFilter: Codable, Sendable {
    /// The collision group or groups, stored as a bit mask, to which the entity belongs.
    public var categoryBitMask: CollisionGroup

    /// The collision group or groups, stored as a bitmask, with which the entity can collide.
    public var collisionBitMask: CollisionGroup

    /// Creates a collision filter.
    public init(
        categoryBitMask: CollisionGroup = .default,
        collisionBitMask: CollisionGroup = .all
    ) {
        self.categoryBitMask = categoryBitMask
        self.collisionBitMask = collisionBitMask
    }
}

/// A bitmask used to define the collision group to which an entity belongs.
public struct CollisionGroup: OptionSet, Codable, Sendable {
    public var rawValue: UInt64

    /// Creates an empty option set.
    public init() {
        self.rawValue = 0
    }

    /// Creates a collision group from a raw value.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The default collision group for objects.
    public static let `default` = Self(rawValue: 1 << 0)

    /// The collision group that represents all groups.
    public static let all = Self(rawValue: .max)
}
