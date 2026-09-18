//
//  Component.swift
//  AdaEngine.
//
//  Created by v.prusakov on 11/2/21.
//

import AdaUtils

/// The base component in ECS paradigm.
/// Component contains data described some entity characteristic in the game world, like:
/// color, transformation and etc.
public protocol Component: QueryTarget, ~Copyable {
    static var componentsInfo: ComponentsInfo { get }

    /// Required components for a component.
    /// AdaEngine will automatically add required components to an entity when the component is added to an entity.
    ///
    /// Example:
    /// ```swift
    /// @Component(required: [Transform.self])
    /// struct Player {
    ///     var health: Int
    /// }
    /// ```
    static var requiredComponents: RequiredComponents { get }
}

/// Required components for a component.
public struct RequiredComponents {
    /// The components that are required for the component.
    public let components: [any (Component & DefaultValue).Type]

    /// Create a new required components.
    public init(components: [any (Component & DefaultValue).Type]) {
        self.components = components
    }
}

extension Component {
    public static var componentsInfo: ComponentsInfo {
        ComponentsInfo(
            componentId: Self.identifier,
            isPlainOldData: _isPOD(Self.self)
        )
    }

    public static var requiredComponents: RequiredComponents {
        RequiredComponents(components: [])
    }
}

public struct ComponentsInfo {
    public let componentId: ComponentId

    /// Plain struct without any references, ARC, etc.
    /// - SeeAlso: _isPOD
    public let isPlainOldData: Bool
}

/// Provides the events related to components.
public enum ComponentEvents {
    /// Event raised after a component has been added to an entity,
    public struct DidAdd: Event {
        /// The component type.
        public let componentType: any Component.Type

        /// The component’s entity.
        public let entity: Entity
    }

    /// Event raised after a component has been modified.
    struct DidChange: Event {
        /// The component type.
        public let componentType: any Component.Type

        /// The component’s entity.
        public let entity: Entity
    }

    /// Event raised before a component is removed from an entity.
    struct WillRemove: Event {
        /// The component type.
        public let componentType: any Component.Type

        /// The component’s entity.
        public let entity: Entity
    }
}
