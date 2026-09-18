//
//  Atomic.swift
//  AdaEngine
//
//  Created by v.prusakov on 4/30/24.
//

import Foundation

/// A property wrapper that allows you to isolate a value with a lock.
@propertyWrapper
@dynamicMemberLookup
public final class LocalIsolated<Value> {
    /// The lock-isolated value.
    public var wrappedValue: Value {
        get {
            self.lock.sync {
                self._value
            }
        }
        set {
            self.lock.sync {
                self._value = newValue
            }
        }
    }

    private var _value: Value
    private let lock: NSRecursiveLock = NSRecursiveLock()

    /// Initializes lock-isolated state around a value.
    ///
    /// - Parameter value: A value to isolate with a lock.
    public init(_ value: @autoclosure @Sendable () throws -> Value) rethrows {
        self._value = try value()
    }

    /// Get a dynamic member from the isolated value.
    /// - Parameter keyPath: The key path to the dynamic member.
    /// - Returns: The dynamic member.
    public subscript<Subject: Sendable>(
        dynamicMember keyPath: KeyPath<Value, Subject>
    ) -> Subject {
        self.lock.sync {
            self._value[keyPath: keyPath]
        }
    }

    /// Initialize a new isolated value.
    /// - Parameter value: The value to isolate.
    public init(wrappedValue value: consuming Value) {
        self._value = value
    }
}

extension LocalIsolated: @unchecked Sendable where Value: Sendable {}

extension LocalIsolated: ExpressibleByBooleanLiteral where Value == Bool {
    public convenience init(booleanLiteral value: BooleanLiteralType) {
        self.init(value)
    }
}

extension LocalIsolated: ExpressibleByUnicodeScalarLiteral where Value == String {
    public convenience init(unicodeScalarLiteral value: String) {
        self.init(value)
    }
}

extension LocalIsolated: ExpressibleByExtendedGraphemeClusterLiteral where Value == String {
    public convenience init(extendedGraphemeClusterLiteral value: String) {
        self.init(value)
    }
}

extension LocalIsolated: ExpressibleByStringLiteral where Value == String {
    public convenience init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }
}

extension LocalIsolated: ExpressibleByIntegerLiteral where Value == Int {
    public convenience init(integerLiteral value: IntegerLiteralType) {
        self.init(value)
    }
}

extension LocalIsolated: ExpressibleByFloatLiteral where Value == Float {
    public convenience init(floatLiteral value: FloatLiteralType) {
        self.init(Float(value))
    }
}

extension NSRecursiveLock {
    @inlinable @discardableResult
    public func sync<R>(_ work: () throws -> R) rethrows -> R {
        self.lock()
        defer { self.unlock() }
        return try work()
    }
}
