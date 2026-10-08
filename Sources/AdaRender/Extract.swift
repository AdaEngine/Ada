//
//  Extract.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 25.11.2025.
//

import AdaECS

/// A property wrapper that allows you to extract a resource from the main world.
@propertyWrapper
public final class Extract<T: SystemParameter>: @unchecked Sendable {
    private var _value: T!
    public var wrappedValue: T {
        _read { yield self._value }
    }

    /// Initialize a new extract.
    public init() {}

    /// Initialize a new extract.
    /// - Parameter from: The world to extract the resource from.
    public init(from world: World) {
        self._value = T(from: world)
    }

    /// Call the extract.
    /// - Returns: The extracted resource.
    public func callAsFunction() -> T {
        self._value
    }
}

extension Extract: SystemParameter {
    public func update(from world: World) {
        if let mainWorld = world.getResource(MainWorld.self)?.world {
            if _value == nil {
                _value = T(from: mainWorld)
            }
            _value?.update(from: mainWorld)
        }
    }
}
