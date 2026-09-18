//
//  LocalIsolated+SystemQuery.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 01.06.2025.
//

import AdaUtils

@propertyWrapper
@dynamicMemberLookup
public final class Local<Value> {
    public var wrappedValue: Value {
        _read {
            yield _value
        }
        _modify {
            yield &_value
        }
    }

    nonisolated private var _value: Value

    /// Initializes lock-isolated state around a value.
    ///
    /// - Parameter value: A value to isolate with a lock.
    public init(_ value: @autoclosure @Sendable () throws -> Value) rethrows {
        self._value = try value()
    }

    /// Get a dynamic member from the isolated value.
    /// - Parameter keyPath: The key path to the dynamic member.
    /// - Returns: The dynamic member.
    public subscript<Subject>(
        dynamicMember keyPath: WritableKeyPath<Value, Subject>
    ) -> Subject {
        _read {
            yield _value[keyPath: keyPath]
        }
        _modify {
            yield &_value[keyPath: keyPath]
        }
    }

    /// Initialize a new isolated value.
    /// - Parameter value: The value to isolate.
    public init(wrappedValue value: consuming Value) {
        self._value = value
    }
}

extension Local: Sendable where Value: Sendable {}
extension Local: Hashable where Value: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(_value)
    }
}
extension Local: Equatable where Value: Equatable {
    public static func == (lhs: Local<Value>, rhs: Local<Value>) -> Bool {
        lhs._value == rhs._value
    }
}

extension Local: SystemParameter {
    // SystemParameter requires this initializer, while Local requires an explicit value.
    // swiftlint:disable:next unavailable_function
    public convenience init(from _: World) {
        preconditionFailure("Local values must be initialized with an explicit value.")
    }

    /// Updates the query state with the given world.
    public func update(from _: World) {}

    public func finish(_: World) {}
}

extension Local: ExpressibleByBooleanLiteral where Value == Bool {
    public convenience init(booleanLiteral value: BooleanLiteralType) {
        self.init(value)
    }
}

extension Local: ExpressibleByUnicodeScalarLiteral where Value == String {
    public convenience init(unicodeScalarLiteral value: String) {
        self.init(value)
    }
}

extension Local: ExpressibleByExtendedGraphemeClusterLiteral where Value == String {
    public convenience init(extendedGraphemeClusterLiteral value: String) {
        self.init(value)
    }
}

extension Local: ExpressibleByStringLiteral where Value == String {
    public convenience init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }
}

extension Local: ExpressibleByIntegerLiteral where Value == Int {
    public convenience init(integerLiteral value: IntegerLiteralType) {
        self.init(value)
    }
}

extension Local: ExpressibleByFloatLiteral where Value == Float {
    public convenience init(floatLiteral value: FloatLiteralType) {
        self.init(Float(value))
    }
}
