//
//  Theme.swift
//  AdaEngine
//

/// A key for accessing typed values stored in a ``Theme``.
///
/// Define a new theme key by conforming to this protocol and specifying a default value:
///
/// ```swift
/// struct MyColorsKey: ThemeKey {
///     static let defaultValue = MyColors()
/// }
/// ```
///
/// Then extend ``Theme`` with a convenience accessor:
///
/// ```swift
/// extension Theme {
///     var myColors: MyColors {
///         get { self[MyColorsKey.self] }
///         set { self[MyColorsKey.self] = newValue }
///     }
/// }
/// ```
public protocol ThemeKey {
    associatedtype Value: Sendable
    static var defaultValue: Value { get }
}

/// A type-safe container of design tokens that can be injected into the view hierarchy via the environment.
///
/// `Theme` is a keyed store, analogous to ``EnvironmentValues``, but dedicated to visual design.
/// A single theme instance groups colors, typography, spacing, and any other design tokens you need.
///
/// ## Usage
///
/// Apply a theme to a view tree:
///
/// ```swift
/// ContentView()
///     .theme(myTheme)
/// ```
///
/// Read the theme inside any view:
///
/// ```swift
/// struct MyView: View {
///     @Environment(\.theme) var theme
///
///     var body: some View {
///         Text("Hello")
///             .foregroundColor(theme[MyColorsKey.self].primary)
///     }
/// }
/// ```
public struct Theme: Sendable {
    private var values: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    /// Accesses the value associated with a custom theme key.
    public subscript<K: ThemeKey>(_ key: K.Type) -> K.Value {
        get { (values[ObjectIdentifier(key)] as? K.Value) ?? K.defaultValue }
        set { values[ObjectIdentifier(key)] = newValue }
    }

    /// Merges another theme into this one. Values from `other` take precedence.
    public mutating func merge(_ other: Self) {
        values.merge(other.values, uniquingKeysWith: { $1 })
    }
}

extension Theme: Hashable {
    public static func == (lhs: Theme, rhs: Theme) -> Bool {
        guard lhs.values.count == rhs.values.count else {
            return false
        }

        for (key, lhsValue) in lhs.values {
            guard let rhsValue = rhs.values[key] else {
                return false
            }

            guard Self.areEquivalent(lhsValue, rhsValue) else {
                return false
            }
        }

        return true
    }

    public func hash(into hasher: inout Hasher) {
        for key in values.keys.sorted(by: { String(describing: $0) < String(describing: $1) }) {
            hasher.combine(key)
            guard let value = values[key] else {
                continue
            }

            if let hashable = value as? AnyHashable {
                hasher.combine(hashable)
            } else if let objectID = Self.objectIdentifierIfReference(value) {
                hasher.combine(objectID)
            } else {
                hasher.combine(ObjectIdentifier(type(of: value)))
            }
        }
    }

    private static func areEquivalent(_ lhs: any Sendable, _ rhs: any Sendable) -> Bool {
        if let lhsHash = lhs as? AnyHashable, let rhsHash = rhs as? AnyHashable {
            return lhsHash == rhsHash
        }

        if let lhsObjectID = objectIdentifierIfReference(lhs),
            let rhsObjectID = objectIdentifierIfReference(rhs) {
            return lhsObjectID == rhsObjectID
        }

        return false
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
