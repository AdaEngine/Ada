//
//  EnvironmentValues.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 30.05.2025.
//

@attached(accessor)
@attached(peer, names: prefixed(__Key_))
public macro Entry() = #externalMacro(module: "AdaEngineMacros", type: "EntryMacro")

/// A key for accessing values in the environment.
///
/// You can create custom environment values by extending the ``EnvironmentValues`` structure with new properties.
/// First declare a new environment key type and specify a value for the required defaultValue property:
///
/// ```swift
/// private struct MyEnvironmentKey: EnvironmentKey {
///     static let defaultValue: String = "Default value"
/// }
/// ```
///
/// Then use the key to define a new environment value property:
/// ```swift
/// extension EnvironmentValues {
///     var myCustomValue: String {
///         get { self[MyEnvironmentKey.self] }
///         set { self[MyEnvironmentKey.self] = newValue }
///     }
/// }
/// ```
///
/// Clients of your environment value never use the key directly. Instead, they use the key path of your
/// custom environment value property. To set the environment value for a view and all its subviews,
/// add the ``View/environment(_:_:)`` view modifier to that view:
///
/// ```swift
/// MyView()
///    .environment(\.myCustomValue, "Another string")
/// ```
///
/// To read the value from inside MyView or one of its descendants, use the ``Environment`` property wrapper:
///
/// ```swift
/// struct MyView: View {
///     @Environment(\.myCustomValue) var customValue: String
///
///     var body: some View {
///         Text(customValue) // Displays "Another string".
///     }
/// }
/// ```
public protocol EnvironmentKey {
    associatedtype Value: Sendable

    static var defaultValue: Value { get }
}

/// A collection of environment values propagated through a view hierarchy.
///
/// AdaEngine exposes a collection of values to your app’s views in an EnvironmentValues structure.
/// To read a value from the structure, declare a property using the ``Environment`` property wrapper
/// and specify the value’s key path.
/// For example, you can read the current scale factor:
///
/// ```swift
/// @ViewEnvironment(\.scaleFactor) private var scaleFactor
/// ```
///
/// You can set or override some values using the ``View/environment(_:_:)`` view modifier:
///
/// ```swift
/// MyView()
///     .environment(\.scaleFactor, 2)
/// ```
///
/// Create a custom environment value by declaring a new property in an extension to the environment values structure and applying the ``Entry()`` macro to the variable declaration:
///
/// ```swift
/// extension EnvironmentValues {
///     @Entry var myCustomValue: String = "Default value"
/// }
/// ```
///
/// Also recommended using extensions for view to modify your environment value:
///
/// ```swift
/// extension View {
///     func myCustomValue(_ myCustomValue: String) -> some View {
///         environment(\.myCustomValue, myCustomValue)
///     }
/// }
/// ```
public struct EnvironmentValues: Sendable {
    private var values: [ObjectIdentifier: any Sendable] = [:]
    private var valueFingerprints: [ObjectIdentifier: Int] = [:]

    /// Monotonically increasing counter — bumped on every mutation.
    /// Used by nodes to detect stale caches without comparing dictionaries.
    public private(set) var version: UInt64 = 0

    /// Incremental fingerprint of stored environment values.
    /// Used together with `version` because independently-created snapshots can have
    /// equal local versions while carrying different values.
    package private(set) var environmentHash: Int = 0

    /// Keys that changed in the most recent mutation batch.
    /// Cleared and rebuilt each time a new mutation starts from version `version - 1`.
    public private(set) var changedKeys: Set<ObjectIdentifier> = []

    /// Creates an environment values instance.
    public init() {}

    /// When non-nil, every subscript READ reports the accessed key's ObjectIdentifier here.
    /// Used once during `@Environment` initialisation to discover which keys it subscribes to.
    /// All accesses occur on the main actor; `nonisolated(unsafe)` avoids a spurious concurrency error
    /// from the nonisolated subscript getter context.
    nonisolated(unsafe) package static var _recordKeyAccess: ((ObjectIdentifier) -> Void)?

    /// Accesses the environment value associated with a custom key.
    public subscript<K: EnvironmentKey>(_ type: K.Type) -> K.Value {
        get {
            unsafe Self._recordKeyAccess?(ObjectIdentifier(type))
            return (self.values[ObjectIdentifier(type)] as? K.Value) ?? K.defaultValue
        }
        set {
            let id = ObjectIdentifier(type)
            let existing = values[id]
            let actuallyChanged = !Self.areEquivalent(existing, newValue)
            values[id] = newValue
            if actuallyChanged {
                replaceFingerprint(for: id, with: Self.makeFingerprint(for: id, value: newValue))
                version &+= 1
                changedKeys.insert(id)
            } else if valueFingerprints[id] == nil {
                replaceFingerprint(for: id, with: Self.makeFingerprint(for: id, value: newValue))
            }
        }
    }

    @_spi(Internal)
    public mutating func merge(_ newValue: Self) {
        for (key, value) in newValue.values {
            let existing = self.values[key]
            let actuallyChanged = !Self.areEquivalent(existing, value)
            self.values[key] = value
            if actuallyChanged {
                let fingerprint = newValue.valueFingerprints[key] ?? Self.makeFingerprint(for: key, value: value)
                replaceFingerprint(for: key, with: fingerprint)
                self.version &+= 1
                self.changedKeys.insert(key)
            } else if valueFingerprints[key] == nil {
                let fingerprint = newValue.valueFingerprints[key] ?? Self.makeFingerprint(for: key, value: value)
                replaceFingerprint(for: key, with: fingerprint)
            }
        }
    }

    /// Returns true if any key in `ids` has a different stored value between `self` and `other`.
    /// Used by subscription filtering in `ViewNode.updateEnvironment` to skip rebuilds
    /// when none of the keys a storage subscribes to actually changed.
    package func hasChangedValues(forKeyIDs ids: Set<ObjectIdentifier>, comparedTo old: Self) -> Bool {
        for id in ids {
            let newVal = values[id]
            let oldVal = old.values[id]
            if !Self.areEquivalent(newVal, oldVal) {
                return true
            }
        }
        return false
    }

    package func hasSameSnapshot(as other: Self) -> Bool {
        version == other.version && environmentHash == other.environmentHash
    }

    package mutating func ensureVersionDiffers(from oldVersion: UInt64) {
        if version == oldVersion {
            version &+= 1
        }
    }

    private mutating func replaceFingerprint(for id: ObjectIdentifier, with newFingerprint: Int) {
        if let oldFingerprint = valueFingerprints[id] {
            environmentHash ^= oldFingerprint
        }

        valueFingerprints[id] = newFingerprint
        environmentHash ^= newFingerprint
    }
}

extension EnvironmentValues {
    private static func makeFingerprint(for id: ObjectIdentifier, value: some Sendable) -> Int {
        var hasher = Hasher()
        hasher.combine(id)

        if let hashable = value as? AnyHashable {
            hasher.combine(0)
            hasher.combine(hashable)
        } else if let objectID = objectIdentifierIfReference(value) {
            hasher.combine(1)
            hasher.combine(objectID)
        } else {
            // Some Sendable environment values are neither Hashable nor references.
            // Build a stable structural fingerprint on assignment; hot environment
            // propagation still compares only `version` and `environmentHash`.
            hasher.combine(2)
            combineStructuralFingerprint(value, into: &hasher)
        }

        return hasher.finalize()
    }

    private static func combineStructuralFingerprint(_ value: Any, into hasher: inout Hasher, depth: Int = 0) {
        hasher.combine(ObjectIdentifier(type(of: value)))

        guard depth < 4 else {
            return
        }

        if let hashable = value as? AnyHashable {
            hasher.combine(0)
            hasher.combine(hashable)
            return
        }

        if let objectID = objectIdentifierIfReference(value) {
            hasher.combine(1)
            hasher.combine(objectID)
            return
        }

        let mirror = Mirror(reflecting: value)
        hasher.combine(mirror.children.count)
        for child in mirror.children {
            hasher.combine(child.label)
            combineStructuralFingerprint(child.value, into: &hasher, depth: depth + 1)
        }
    }

    private static func areEquivalent(_ lhs: (any Sendable)?, _ rhs: (any Sendable)?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (nil, _),
            (_, nil):
            return false
        case let (lhs?, rhs?):
            if let lhsHash = lhs as? AnyHashable, let rhsHash = rhs as? AnyHashable {
                return lhsHash == rhsHash
            }

            if let lhsObjectID = objectIdentifierIfReference(lhs),
                let rhsObjectID = objectIdentifierIfReference(rhs) {
                return lhsObjectID == rhsObjectID
            }

            return false
        }
    }

    private static func objectIdentifierIfReference(_ value: some Sendable) -> ObjectIdentifier? {
        objectIdentifierIfReference(value as Any)
    }

    private static func objectIdentifierIfReference(_ value: Any) -> ObjectIdentifier? {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else {
                return nil
            }
            return objectIdentifierIfReference(wrapped)
        }

        guard mirror.displayStyle == .class else {
            return nil
        }

        return ObjectIdentifier(value as AnyObject)
    }
}

extension EnvironmentValues {
    @TaskLocal package static var current = EnvironmentValues()
}

/// Updates the current environment for the duration of an asynchronous operation.
public func withEnvironmentValues<T>(
    _ updateValues: @Sendable (inout EnvironmentValues) -> Void,
    operation: () async throws -> T
) async rethrows -> T {
    var current = EnvironmentValues.current
    updateValues(&current)
    return try await EnvironmentValues.$current.withValue(current) {
        try await operation()
    }
}

extension EnvironmentValues {
    @Entry public var context: EnvironmentContext = .runtime
}

public enum EnvironmentContext: Sendable {
    /// This context is automatically inferred when running code from an XCTestCase or Swift Testing.
    case test

    /// This context is the default when a ``test`` context is not detected.
    case runtime
}
