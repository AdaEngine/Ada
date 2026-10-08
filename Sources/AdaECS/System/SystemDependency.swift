//
//  SystemDependency.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/12/23.
//

/// Defines update order relative to other systems. An object that specifies the update order between multiple systems.
///
/// If you need to specify the update order between your system and other systems in your app, you can do that using this property.
///
/// ```swift
/// @PlainSystem(dependencies: [
///     .after(EnemyChasingSystem.self), // Run MovementSystem after EnemyChasingSystem
///     .before(BulletSystem.self) // Run MovementSystem before BulletSystem
/// ])
/// struct MovementSystem {
///     // ...
/// }
/// ```
public enum SystemDependency: Sendable {
    /// Run the system before the specified system by name.
    case before(String)

    /// Run the system after the specified system by name.
    case after(String)
}

extension SystemDependency {
    /// Run the system before the specified system.
    public static func before<T: System>(_ system: T.Type) -> SystemDependency {
        return .before(system.swiftName)
    }

    /// Run the system after the specified system.
    public static func after<T: System>(_ system: T.Type) -> SystemDependency {
        return .after(system.swiftName)
    }
}

extension SystemDependency: Equatable {
    /// Check if two system dependencies are equal.
    /// - Parameter lhs: The left system dependency.
    /// - Parameter rhs: The right system dependency.
    /// - Returns: True if the two system dependencies are equal, otherwise false.
    public static func == (lhs: SystemDependency, rhs: SystemDependency) -> Bool {
        switch lhs {
        case let .before(system):
            switch rhs {
            case let .before(rhsSystem):
                return system == rhsSystem
            case .after:
                return false
            }
        case let .after(system):
            switch rhs {
            case .before:
                return false
            case let .after(rhsSystem):
                return system == rhsSystem
            }
        }
    }
}
