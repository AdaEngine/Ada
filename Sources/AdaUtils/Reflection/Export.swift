//
//  Export.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/6/22.
//

// TODO: Add export name
// TODO: Add more options for export
// TODO: Should me mutating
// TODO: Make it macro to avoid runtime?

/// Fields marked as `@Export` can be serialized and deserialized by AdaEngine.
/// If you want serialize your ``Component`` object, annotate properties inside them as `@Export`.
/// - Note: You can use `private`, `private` modifiers, because `@Export` use reflection
@propertyWrapper
public struct Export<T: Codable>: Codable, @unchecked Sendable {
    private final class Storage {
        var skipped: Bool = false
        var hasChanges: Bool = false
        var editorInfo: EditorInfo?
        var value: T {
            didSet {
                self.hasChanges = true
            }
        }

        init(value: T) {
            self.value = value
        }
    }

    private let storage: Storage

    public var wrappedValue: T {
        _read {
            yield self.storage.value
        }
        _modify {
            yield &self.storage.value
        }
    }

    public init(wrappedValue: T) {
        self.storage = .init(value: wrappedValue)
    }

    //    public init(wrappedValue: T) where T: Asset {
    //        self.storage = .init(value: wrappedValue)
    //        self.storage.editorInfo = EditorInfo(modifiers: .resource)
    //    }

    public init(wrappedValue: T) where T: CaseIterable {
        self.storage = .init(value: wrappedValue)
        self.storage.editorInfo = EditorInfo(
            modifiers: .enum(EnumModifier(cases: T.allCases.map { String(reflecting: $0) }))
        )
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.storage = .init(value: try container.decode(T.self))
    }

    public func encode(to encoder: Encoder) throws {
        if encoder.userInfo[.editorIntrospection] != nil && self.storage.editorInfo != nil {
            var container = encoder.container(keyedBy: CodingName.self)
            try container.encode(self.wrappedValue, forKey: .value)
            try container.encode(self.storage.editorInfo, forKey: .editor)
        } else if self.storage.hasChanges {
            var container = encoder.singleValueContainer()
            try container.encode(self.wrappedValue)
        }
    }
}

// MARK: - _ExportCodable

extension Export: _ExportCodable {
    public func decode(from container: DecodingContainer, propertyName: String, userInfo _: [CodingUserInfoKey: Any]) throws {
        guard let value = try container.decodeIfPresent(T.self, forKey: CodingName(stringValue: propertyName)) else {
            return
        }

        self.storage.value = value
    }

    public func encode(to container: inout EncodingContainer, propertyName: String, userInfo: [CodingUserInfoKey: Any]) throws {
        /// we have difference between initial value
        if self.storage.hasChanges && !self.storage.skipped {
            try container.encode(self.wrappedValue, forKey: CodingName(stringValue: propertyName))
        }

        if userInfo[.editorIntrospection] != nil {
            try container.encodeIfPresent(self.storage.editorInfo, forKey: .editor)
        }
    }
}

extension Export {
    public init(wrappedValue: T, range: ClosedRange<Float>? = nil, stride: Float? = nil) where T: FloatingPoint {
        self.init(wrappedValue: wrappedValue)
        self.storage.editorInfo = EditorInfo(
            modifiers: .float(FloatingPointModifier(range: range, stride: stride))
        )
    }

    public init(wrappedValue: T, skipped: Bool) {
        self.init(wrappedValue: wrappedValue)
        self.storage.skipped = skipped
    }
}

extension Export {
    enum Modifiers: Codable {
        case float(FloatingPointModifier)
        case `enum`(EnumModifier)
        case resource
    }

    struct FloatingPointModifier: Codable {
        let range: ClosedRange<Float>?
        let stride: Float?
    }

    struct EnumModifier: Codable {
        let cases: [String]
    }

    struct EditorInfo: Codable {
        var modifiers: Modifiers?
    }
}

extension CodingUserInfoKey {
    /// It will be used for editor feature. If type will be reflected with this key, we want to collect and show their properties on the editor screen.
    static let editorIntrospection = CodingUserInfoKey(rawValue: "export.editor.introspection")
        .unwrap(message: "Editor introspection coding key is invalid.")
}

/// A protocol that defines the default value of a type.
public protocol DefaultValue: Sendable {
    /// The default value of the type.
    static var defaultValue: Self { get }
}

/// Annotate property as `@NoExport` if you don't need that a property will be serialized.
/// ``Encodable`` protocol will ignore that property.
@propertyWrapper
public struct NoExport<T: DefaultValue>: Codable, Sendable {
    /// The wrapped value.
    public var wrappedValue: T

    /// Initialize a new no export.
    ///
    /// - Parameter wrappedValue: The wrapped value.
    public init(wrappedValue: T) {
        self.wrappedValue = wrappedValue
    }

    /// Initialize a new no export.
    ///
    /// - Parameter wrappedValue: The wrapped value.
    public init() {
        self.wrappedValue = T.defaultValue
    }

    /// Initialize a new no export.
    ///
    /// - Parameter wrappedValue: The wrapped value.
    public init(from _: Decoder) throws {
        self.wrappedValue = T.defaultValue
    }

    /// Encode the no export.
    ///
    /// - Parameter encoder: The encoder.
    public func encode(to _: Encoder) throws {}
}
