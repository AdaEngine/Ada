//
//  PhysicsMassProperties.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/12/22.
//

import Math

/// Mass properties of a physics body.
public struct PhysicsMassProperties: Codable, Sendable {
    /// The mass in kilograms.
    public var mass: Float

    /// The inertia in kilograms per square meter.
    public var inertia: Vector3

    public init(mass: Float, inertia: Vector3) {
        self.mass = mass
        self.inertia = inertia
    }

    public init() {
        self.mass = 0
        self.inertia = .zero
    }
}
