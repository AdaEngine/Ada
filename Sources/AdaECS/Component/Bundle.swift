//
//  Bundle.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 13.06.2025.
//

/// Collection of components.
///
/// Example:
/// ```swift
/// @Bundle
/// struct PlayerBundle {
///     var player: Player
/// }
///
/// let playerBundle = PlayerBundle(player: Player(name: "John"))
/// world.spawn(bundle: playerBundle)
/// ```
public protocol ComponentsBundle: Sendable, ~Copyable {
    /// The components that are part of the bundle.
    var components: [any Component] { get }
}

extension ComponentsBundle {
    // Extends components bundle with another components bundle.
    public func extend<T: ComponentsBundle>(_ bundle: T) -> ChainedComponentsBundle {
        ChainedComponentsBundle(self.components + bundle.components)
    }

    // Extends components bundle with components.
    public func extend(@ComponentsBuilder _ components: () -> ComponentsBundle) -> ChainedComponentsBundle {
        ChainedComponentsBundle(self.components + components().components)
    }
}

public struct ChainedComponentsBundle: ComponentsBundle {
    public let components: [any Component]

    init(_ components: [any Component]) {
        self.components = components
    }
}
