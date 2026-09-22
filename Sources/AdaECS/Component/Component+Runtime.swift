//
//  Component+Runtime.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/24/22.
//

import Foundation

// TODO: (Vlad) Add components list to editor and generate file with registered components.
// TODO: (Vlad) We can think about `swift_getMangledTypeName` and `swift_getTypeByMangledNameInContext`

// We should register our components in engine, because we should initiate them in memory
// This can help to avoid registering components during runtime.
extension Component {
    /// Call this method to add component to the engine.
    /// When engine will initiate component from scene file, it will try to find
    /// component in registered list.
    /// Otherwise component will not be initialized.
    @MainActor
    public static func registerComponent() {
        ComponentStorage.addComponent(self)
        if let inspectableType = self as? any ReflectableComponent.Type {
            ComponentReflectionRegistry.register(inspectableType.componentDescriptor)
        }
    }
}

extension Component {
    static var swiftName: String {
        TypeNameCache.name(for: self)
    }

    /// Return identifier of component based on Component.Type
    @inline(__always) public static var identifier: ComponentId {
        ComponentId(id: Int(bitPattern: ObjectIdentifier(self)))
    }
}

enum ComponentStorage {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registeredComponents: [String: any Component.Type] = [:]
    nonisolated(unsafe) private static var defaultFactories: [String: @Sendable () -> any Component] = [:]
    nonisolated(unsafe) private static var runtimeConstructors: [String: RegisteredRuntimeComponentConstructor] = [:]

    /// Return registered component or try to find it by NSClassFromString (works only for objc runtime)
    static func getRegisteredComponent(for name: String) -> (any Component.Type)? {
        let registered = lock.withLock { unsafe registeredComponents[name] }
        return registered ?? (NSClassFromString(name) as? (any Component.Type))
    }

    static func addComponent<T: Component>(_ type: T.Type) {
        let name = T.swiftName
        lock.withLock { unsafe registeredComponents[name] = type }
    }

    static func addComponent<T: Component>(_ type: T.Type, named name: String) {
        lock.withLock { unsafe registeredComponents[name] = type }
    }

    static func addDefaultFactory(_ factory: @escaping @Sendable () -> any Component, named name: String) {
        lock.withLock { unsafe defaultFactories[name] = factory }
    }

    static func addRuntimeConstructor(
        _ descriptor: RuntimeComponentConstructorDescriptor,
        named name: String,
        makeDefault: (@Sendable () -> any Component)?
    ) {
        let constructor = RegisteredRuntimeComponentConstructor(
            name: name,
            descriptor: descriptor,
            makeDefault: makeDefault
        )
        lock.withLock { unsafe runtimeConstructors[name] = constructor }
    }

    static func makeDefaultComponent(named name: String) -> (any Component)? {
        let factory = lock.withLock { unsafe defaultFactories[name] }
        return factory?()
    }

    static func allRegisteredComponents() -> [String: any Component.Type] {
        lock.withLock { unsafe registeredComponents }
    }

    static func allRuntimeConstructors() -> [String: RegisteredRuntimeComponentConstructor] {
        lock.withLock { unsafe runtimeConstructors }
    }
}

// This hack can help us to find struct or classes in binary

// https://github.com/apple/swift/blob/4435a37088b20fa7eca3c48947b0532e5221629b/stdlib/public/core/Misc.swift
// @_silgen_name("swift_getTypeByMangledNameInContext")
// internal func _getTypeByMangledNameUntrusted(
//  _ name: UnsafePointer<UInt8>,
//  _ nameLength: UInt)
//  -> Any.Type?
//
// @_silgen_name("swift_getMangledTypeName")
// public func _getTypeName(_ type: Any.Type, qualified: Bool) -> (UnsafePointer<UInt8>, Int)
