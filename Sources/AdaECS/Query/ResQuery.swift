//
//  ResQuery.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 22.05.2025.
//

import AdaUtils

/// A property wrapper that allows you to query a resource from a world.
@dynamicMemberLookup
@propertyWrapper
public final class Res<T: Resource>: @unchecked Sendable {
    /// The value of the query.
    private var _value: T?

    /// The wrapped value of the query.
    public var wrappedValue: T {
        _read {
            guard let value = _value else {
                preconditionFailure("Resource \(T.self) has not been initialized.")
            }
            yield value
        }
    }

    /// Initialize a new resource query.
    public init() {
        self._value = nil
    }

    /// Initialize a new resource query.
    /// - Parameter world: The world that will be used to initialize the query.
    public init(from world: World) {
        self._value = world.getResource(T.self)
            .unwrap(message: "Resource \(T.self) not found in world. Make sure to call world.insertResource(_:) before using Res.")
    }

    /// Get the value of the query.
    /// - Returns: The value of the query.
    public func callAsFunction() -> T {
        guard let value = _value else {
            preconditionFailure("Resource \(T.self) has not been initialized.")
        }
        return value
    }

    public subscript<U>(dynamicMember dynamicMember: KeyPath<T, U>) -> U {
        self.wrappedValue[keyPath: dynamicMember]
    }
}

extension Res: SystemParameter {
    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        access.addResourceRead(T.self)
        return access
    }

    public func update(from world: World) {
        guard let resource = T.getFromWorld(world) else {
            preconditionFailure("Resource \(T.self) not found in world. Make sure to call world.insertResource(_:) before using Res.")
        }

        self._value = resource
    }
}

extension Optional: Resource where Wrapped: Resource {
    public static var resourceIdentifier: ObjectIdentifier {
        Wrapped.resourceIdentifier
    }

    public static func getFromWorld(_ world: borrowing World) -> Wrapped?? {
        world.getResource(Wrapped.self)
    }
}

/// A property wrapper that allows you to query a mutable resource from a world.
@dynamicMemberLookup
@propertyWrapper
public final class ResMut<T: Resource>: @unchecked Sendable {
    /// The value of the query.
    private var _value: Ref<T>?

    /// The wrapped value of the query.
    public var wrappedValue: T {
        _read {
            guard let value = self._value else {
                preconditionFailure("Mutable resource \(T.self) has not been initialized.")
            }
            yield value.wrappedValue
        }
        _modify {
            guard let value = self._value else {
                preconditionFailure("Mutable resource \(T.self) has not been initialized.")
            }
            yield &value.wrappedValue
        }
    }

    /// Return reference to resource
    public var projectedValue: Ref<T>? {
        _read {
            yield _value
        }
    }

    /// Initialize a new resource query.
    public init() {
        self._value = nil
    }

    /// Initialize a new resource query.
    /// - Parameter world: The world that will be used to initialize the query.
    public init(from world: World) {
        self._value = world.getRefResource(T.self)
    }

    /// Get the value of the query.
    /// - Returns: The value of the query.
    public func callAsFunction() -> Ref<T>? {
        _value
    }

    public subscript<U>(dynamicMember dynamicMember: WritableKeyPath<T, U>) -> U {
        _read {
            yield self.wrappedValue[keyPath: dynamicMember]
        }
        _modify {
            yield &self.wrappedValue[keyPath: dynamicMember]
        }
    }
}

extension ResMut: SystemParameter {
    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        access.addResourceWrite(T.self)
        return access
    }

    public func update(from world: World) {
        self._value = world.getRefResource(T.self)
    }
}
