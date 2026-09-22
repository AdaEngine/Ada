//
//  ECSMacros.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/18/25.
//

import AdaUtils

/// A component that exposes generated, runtime-agnostic field metadata.
public protocol ReflectableComponent: Component {
    static var componentDescriptor: ReflectedComponentDescriptor { get }
}

/// A macro for creating a component.
/// A component macro is more preffered way to create a component.
/// When you use a component macro, you will atomatically conforms ``Component`` protocol
/// and also get DSL style to modify your component.
///
/// Example:
/// ```swift
/// @Component
/// struct Transform {
///     var position: Vector3
/// }
///
/// let transform = Transform()
///                     .setPosition(Vector3(0, 0, 0))
/// ```
@attached(member)
@attached(
    extension,
    conformances: Component, ReflectableComponent, RuntimeConstructibleComponent,
    names: arbitrary
)
public macro Component(
    required: [any (Component & DefaultValue).Type] = []
) = #externalMacro(module: "AdaEngineMacros", type: "ComponentMacro")

/// Selects the Swift initializer used by AdaScript host construction.
/// ``Component()`` consumes this marker and generates the direct bridge.
@attached(peer)
public macro AdaScriptInit() = #externalMacro(
    module: "AdaEngineMacros",
    type: "AdaScriptInitMacro"
)

/// A macro for creating a bundle.
/// A bundle macro is more preffered way to create a bundle.
/// When you use a bundle macro, you will atomatically conforms ``Bundle`` protocol.
///
/// Example:
/// ```swift
/// @Bundle
/// struct PlayerBundle {
///     var position: Vector3
///     var player: Player
/// }
///
/// world.spawn(bundle:
///     PlayerBundle(
///         position: [10, 0, 10],
///         player: Player(team: .red)
///     )
/// )
/// ```
@attached(member, names: named(components))
@attached(extension, names: arbitrary, conformances: ComponentsBundle)
public macro Bundle() = #externalMacro(module: "AdaEngineMacros", type: "BundleMacro")

/// A macro for creating a system.
/// You can pass as many parameters as you want, but they must be a conforms a ``SystemParameter`` protocol.
///
/// - Parameters:
///   - dependencies: An array of system dependencies.
///
/// Example:
/// ```swift
/// @PlainSystem(dependencies: [.before(PhysicsSystem.self)])
/// struct MovementSystem: System {
///     @Query<Ref<Transform>, Velocity>
///     private var query
///
///     @Res
///     private var resources: Gravity?
///
///     init(world: World) { }
///
///     func update(context: UpdateContext) {
///         for (transform, velocity) in query {
///             transform.position += velocity.value * context.deltaTime
///         }
///     }
/// }
/// ```
@attached(member, names: named(queries), named(dependencies))
@attached(extension, names: arbitrary, conformances: System)
public macro PlainSystem(
    dependencies: [SystemDependency] = []
) = #externalMacro(module: "AdaEngineMacros", type: "SystemMacro")

/// A macro for creating a system from a function.
/// You can pass as many parameters as you want, but they must be a conforms a ``SystemParameter`` protocol.
///
/// - Parameters:
///   - dependencies: An array of system dependencies.
///
/// Example:
/// ```swift
/// @System(dependencies: [.before(PhysicsSystem.self)])
/// func Movement(
///     query: Query<Ref<Transform>, Velocity>,
///     resources: Res<Gravity>,
/// ) {
///     // ...
/// }
///
/// world.addSystem(MovementSystem.self)
/// ```
/// }

@attached(peer, names: suffixed(System), conformances: System)
public macro System(
    dependencies: [SystemDependency] = []
) = #externalMacro(module: "AdaEngineMacros", type: "SystemMacro")
