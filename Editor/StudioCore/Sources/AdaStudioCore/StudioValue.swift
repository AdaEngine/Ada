#if canImport(CoreFoundation)
import CoreFoundation
#endif
import Foundation

/// Portable scene and tool values, shared by native Studio and the browser.
public enum StudioValue: Codable, Equatable, Sendable {
    case null, bool(Bool), int(Int), uint(UInt64), double(Double), string(String), array([Self]), object([String: Self])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(UInt64.self) { self = .uint(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String: Self].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .uint(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(_ key: String) -> Self {
        get { if case .object(let values) = self { values[key] ?? .null } else { .null } }
        set { var values = object; values[key] = newValue; self = .object(values) }
    }
    public var object: [String: Self] { if case .object(let v) = self { v } else { [:] } }
    public var array: [Self] { if case .array(let v) = self { v } else { [] } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var number: Double? {
        switch self { case .int(let v): Double(v); case .uint(let v): Double(v); case .double(let v): v; default: nil }
    }
    public var text: String {
        switch self {
        case .string(let v): v
        case .null: ""
        default: (try? String(decoding: encoded(), as: UTF8.self)) ?? ""
        }
    }
    /// Parses JSON values without probing every possible Codable type at every node.
    public static func decode(_ data: Data) throws -> Self {
        try fromJSON(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    private static func fromJSON(_ value: Any) throws -> Self {
        if value is NSNull { return .null }
        if let number = value as? NSNumber {
            let kind = unsafe String(cString: number.objCType)
            #if canImport(CoreFoundation)
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            #else
            if kind == "c" { return .bool(number.boolValue) }
            #endif
            if kind == "f" || kind == "d" {
                let value = number.doubleValue
                if let integer = Int(exactly: value) { return .int(integer) }
                if let integer = UInt64(exactly: value) { return .uint(integer) }
                return .double(value)
            }
            if kind == "Q" {
                let value = number.uint64Value
                return Int(exactly: value).map(Self.int) ?? .uint(value)
            }
            return .int(number.intValue)
        }
        if let string = value as? String { return .string(string) }
        if let array = value as? [Any] { return .array(try array.map(fromJSON)) }
        if let object = value as? [String: Any] { return .object(try object.mapValues(fromJSON)) }
        throw StudioError.invalid("Unsupported JSON value.")
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public enum StudioError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String), conflict, unavailable(String), authenticationRequired
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message): message
        case .conflict: "Версия проекта изменилась. Обновите её перед повторной операцией."
        case .authenticationRequired: "Войдите в Ada Cloud, чтобы продолжить."
        }
    }
}
