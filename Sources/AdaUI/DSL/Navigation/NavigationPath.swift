//
//  NavigationPath.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 25.03.2026.
//

/// A type-erased list of data representing the content of a navigation stack.
///
/// The path is a value type and AdaUI mutates it on the UI actor through
/// bindings/state. `AnyHashable` does not express Sendable, so the conformance is
/// unchecked and relies on the stored values being UI-bound navigation data.
public struct NavigationPath: @unchecked Sendable {
    private var elements: [AnyHashable] = []

    /// The number of elements in this path.
    public var count: Int { elements.count }

    /// A Boolean that indicates whether this path is empty.
    public var isEmpty: Bool { elements.isEmpty }

    /// Creates an empty navigation path.
    public init() {}

    /// Appends a new value to the end of this path.
    public mutating func append<V: Hashable>(_ value: V) {
        elements.append(AnyHashable(value))
    }

    /// Removes the last k elements of this path.
    public mutating func removeLast(_ k: Int = 1) {
        guard k > 0 else {
            return
        }
        elements.removeLast(min(k, elements.count))
    }

    /// The top-most (last) element of the path, or nil if empty.
    var topElement: AnyHashable? {
        elements.last
    }
}
