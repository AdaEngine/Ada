import Foundation

public enum EditorCloudValue: Codable, Sendable, Equatable, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    case object([String: Self])
    case array([Self])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null
    public init(dictionaryLiteral elements: (String, Self)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    public init(arrayLiteral elements: Self...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral _: ()) { self = .null }
    public subscript(_ key: String) -> Self {
        get { object[key] ?? .null }
        set {
            var fields = object
            fields[key] = newValue
            self = .object(fields)
        }
    }
    public var object: [String: Self] {
        if case let .object(value) = self {
            value
        } else {
            [:]
        }
    }
    public var array: [Self] {
        if case let .array(value) = self {
            value
        } else {
            []
        }
    }
    public var string: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }
    public var int: Int64? {
        if case let .integer(value) = self {
            value
        } else {
            nil
        }
    }
    public var bool: Bool? {
        if case let .bool(value) = self {
            value
        } else {
            nil
        }
    }
    public var seconds: Double {
        switch self {
        case let .number(n): n
        case let .integer(n): Double(n)
        default: 0
        }
    }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let v = try? value.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? value.decode(Int64.self) {
            self = .integer(v)
        } else if let v = try? value.decode(Double.self) {
            self = .number(v)
        } else if let v = try? value.decode(String.self) {
            self = .string(v)
        } else if let v = try? value.decode([Self].self) {
            self = .array(v)
        } else {
            self = .object(try value.decode([String: Self].self))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .object(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .integer(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
