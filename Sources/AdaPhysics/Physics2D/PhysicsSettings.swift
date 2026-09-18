//
//  PhysicsSettings.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/8/23.
//

// TODO: Looks like we should use this enum instead of `Engine.ticksPerSecond` value.

/// Base physics settings for all physics worlds.
public enum PhysicsSettings {
    /// Setup physics ticks per second. Default value is equal 60 ticks per second.
    @MainActor public static var ticksPerSecond: Int = 60
}
