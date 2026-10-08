//
//  View+Observable.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 06.07.2024.
//

import AdaUtils
@unsafe @preconcurrency import Observation

extension View {
    /// Places an observable object in the view's environment.
    ///
    /// - Parameter object: The object to set for this object's type in the
    ///   environment, or `nil` to clear an object of this type from the
    ///   environment.
    ///
    /// - Returns: A view that has the specified object in its environment.
    public func environment<T: Observable & AnyObject>(_ object: T?) -> some View {
        self.transformEnvironment(\.observableStorage) { storage in
            storage.insertValue(object)
        }
    }
}

struct ObservableStorageEnvironment: @unchecked Sendable, Hashable {
    // AdaUI environment propagation is MainActor-only. `@unchecked Sendable` is
    // limited to storing Observation object references inside EnvironmentValues,
    // whose key values must be Sendable even when the observable itself is UI-bound.
    private var storedValues: [ObjectIdentifier: any Observable & AnyObject] = [:]

    mutating func insertValue<T: Observable & AnyObject>(_ value: T?) {
        storedValues[ObjectIdentifier(T.self)] = value
    }

    func getValue<T: Observable & AnyObject>(_ type: T.Type) -> T {
        guard let value = storedValues[ObjectIdentifier(T.self)] else {
            fatalError("Can't find object in view environment with type \(type)")
        }

        return value as! T
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.storedValues.count == rhs.storedValues.count else {
            return false
        }

        for (key, lhsValue) in lhs.storedValues {
            guard
                let rhsValue = rhs.storedValues[key],
                ObjectIdentifier(lhsValue) == ObjectIdentifier(rhsValue)
            else {
                return false
            }
        }

        return true
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(storedValues.count)

        for (key, value) in storedValues.sorted(by: { lhs, rhs in
            String(describing: lhs.key) < String(describing: rhs.key)
        }) {
            hasher.combine(key)
            hasher.combine(ObjectIdentifier(value))
        }
    }
}

extension EnvironmentValues {
    @Entry var observableStorage: ObservableStorageEnvironment = ObservableStorageEnvironment()
}
