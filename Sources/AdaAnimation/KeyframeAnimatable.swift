//
//  KeyframeAnimatable.swift
//  AdaAnimation
//

import AdaECS

/// A type that defines how an animated value struct is applied back to ECS components.
///
/// Implement this protocol on a struct that mirrors the components you want to animate:
/// ```swift
/// struct MyAnim: KeyframeAnimatable {
///     var transform = Transform()
///
///     func apply(to entityId: Entity.ID, in world: World) {
///         world.insert(transform, for: entityId)
///     }
/// }
/// ```
public protocol KeyframeAnimatable: Sendable {
    /// Write the current animated values into the entity's ECS components.
    func apply(to entityId: Entity.ID, in world: World)
}
