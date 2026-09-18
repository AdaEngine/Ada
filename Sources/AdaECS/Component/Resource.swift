//
//  Resource.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 23.05.2025.
//

import Foundation

/// The singleton resource that passed to the ecs world.
/// Only one instance of the resource is allowed in the world.
public protocol Resource: Sendable {
    /// Stable runtime identifier used by ECS access tracking.
    static var resourceIdentifier: ObjectIdentifier { get }

    static func getFromWorld(_ world: borrowing World) -> Self?
}

extension Resource {
    public static var resourceIdentifier: ObjectIdentifier {
        ObjectIdentifier(Self.self)
    }

    /// Get a resource from the world.
    /// - Parameter world: The world to get the resource from.
    /// - Returns: The resource if it exists, otherwise nil.
    public static func getFromWorld(_ world: borrowing World) -> Self? {
        world.getResource(Self.self)
    }
}

/// Init the object from a world
public protocol WorldInitable: Sendable {
    /// Initialize the resource from a world.
    /// - Parameter world: The world to initialize the resource from.
    /// - Returns: The initialized resource.
    init(from world: World)
}

// TODO: (Vlad) Add components list to editor and generate file with registered components.
// TODO: (Vlad) We can think about `swift_getMangledTypeName` and `swift_getTypeByMangledNameInContext`

// We should register our resources in engine, because we should initiate them in memory
// This can help to avoid registering resources during runtime.
extension Resource {
    /// Call this method to add resource to the engine.
    /// When engine will initiate resource from scene file, it will try to find
    /// resource in registered list.
    /// Otherwise resource will not be initialized.
    @MainActor
    public static func registerResource() {
        ResourceStorage.addResource(self)
    }
}

extension Resource {
    static var swiftName: String {
        TypeNameCache.name(for: self)
    }

    /// Return identifier of resource based on Resource.Type
    @inline(__always) static var identifier: ObjectIdentifier {
        ObjectIdentifier(self)
    }
}

enum ResourceStorage {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registeredResources: [String: Resource.Type] = [:]

    /// Return registered resource or try to find it by NSClassFromString (works only for objc runtime)
    static func getRegisteredResource(for name: String) -> Resource.Type? {
        let registered = lock.withLock { unsafe registeredResources[name] }
        return registered ?? (NSClassFromString(name) as? Resource.Type)
    }

    static func addResource<T: Resource>(_ type: T.Type) {
        let name = T.swiftName
        lock.withLock { unsafe registeredResources[name] = type }
    }

    static func addResource<T: Resource>(_ type: T.Type, named name: String) {
        lock.withLock { unsafe registeredResources[name] = type }
    }

    static func allRegisteredResources() -> [String: any Resource.Type] {
        lock.withLock { unsafe registeredResources }
    }
}
