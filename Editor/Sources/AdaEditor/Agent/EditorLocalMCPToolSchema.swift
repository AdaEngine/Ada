import Foundation

/// Validates the supported JSON Schema subset without running server-supplied code or resolving references.
struct EditorLocalMCPToolSchema: Sendable {
    let value: EditorCloudValue

    private static let types: Set<String> = ["object", "array", "string", "integer", "number", "boolean", "null"]
    private static let countKeys = ["minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"]
    private static let numberKeys = ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"]
    private static let keys: Set<String> = [
        "type", "properties", "required", "additionalProperties", "items", "enum", "const",
        "title", "description", "default", "examples", "$schema", "$comment", "deprecated", "readOnly", "writeOnly"
    ]

    init(_ value: EditorCloudValue) throws {
        guard value["type"].string == "object", Self.isBounded(value, remaining: 16_000, depth: 0), Self.isSupported(value, depth: 0),
              (try JSONEncoder().encode(value)).count <= 16_000 else {
            throw Failure.schema
        }
        self.value = value
    }

    func validate(_ input: EditorCloudValue) throws {
        guard case .object = input, Self.isBounded(input, remaining: 16_000, depth: 0), Self.matches(input, schema: value),
              (try JSONEncoder().encode(input)).count <= 16_000 else { throw Failure.arguments }
    }

    private static func isSupported(_ value: EditorCloudValue, depth: Int) -> Bool {
        if case .bool = value { return true }
        guard depth <= 10, case let .object(schema) = value, Set(schema.keys).isSubset(of: keys.union(countKeys).union(numberKeys)) else { return false }
        if let dialect = schema["$schema"], !["https://json-schema.org/draft/2020-12/schema", "https://json-schema.org/draft/2019-09/schema"].contains(dialect.string ?? "") {
            return false
        }
        if let type = schema["type"], let names = type.string.map({ [$0] }) ?? stringList(type), !names.isEmpty {
            guard names.allSatisfy(types.contains), Set(names).count == names.count else { return false }
        } else if schema["type"] != nil { return false }
        if let properties = schema["properties"] {
            guard case let .object(fields) = properties, fields.values.allSatisfy({ isSupported($0, depth: depth + 1) }) else { return false }
        }
        if let required = schema["required"] {
            guard let names = stringList(required), Set(names).count == names.count else { return false }
        }
        if let allowed = schema["enum"] {
            guard case let .array(values) = allowed, !values.isEmpty else { return false }
        }
        for key in ["additionalProperties", "items"] {
            if let child = schema[key], !isSupported(child, depth: depth + 1) { return false }
        }
        return countKeys.allSatisfy { key in schema[key].map { $0.int.map { $0 >= 0 } == true } ?? true } &&
            numberKeys.allSatisfy { key in schema[key].map { number($0) != nil } ?? true }
    }

    private static func matches(_ input: EditorCloudValue, schema: EditorCloudValue) -> Bool {
        if let accept = schema.bool { return accept }
        let constraints = schema.object
        if let type = constraints["type"] {
            let names = type.string.map { [$0] } ?? type.array.compactMap(\.string)
            guard names.contains(where: { hasType(input, $0) }) else { return false }
        }
        if let constant = constraints["const"], !equal(input, constant) { return false }
        if let choices = constraints["enum"], !choices.array.contains(where: { equal(input, $0) }) { return false }
        switch input {
        case let .object(fields):
            let properties = schema["properties"].object
            let additional = constraints["additionalProperties"] ?? true
            return allowedCount(fields.count, schema["minProperties"], schema["maxProperties"]) &&
                schema["required"].array.compactMap(\.string).allSatisfy { fields[$0] != nil } &&
                fields.allSatisfy { matches($0.value, schema: properties[$0.key] ?? additional) }
        case let .array(values):
            return allowedCount(values.count, schema["minItems"], schema["maxItems"]) && values.allSatisfy { matches($0, schema: constraints["items"] ?? true) }
        case let .string(text):
            return allowedCount(text.unicodeScalars.count, schema["minLength"], schema["maxLength"])
        case .integer, .number:
            guard let amount = number(input) else { return false }
            return amount >= (number(schema["minimum"]) ?? -.greatestFiniteMagnitude) && amount <= (number(schema["maximum"]) ?? .greatestFiniteMagnitude) &&
                number(schema["exclusiveMinimum"]).map { amount > $0 } != false && number(schema["exclusiveMaximum"]).map { amount < $0 } != false
        default: return true
        }
    }

    private static func hasType(_ input: EditorCloudValue, _ type: String) -> Bool {
        switch (type, input) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null): true
        case ("integer", .integer), ("number", .integer): true
        case let ("integer", .number(value)): value.isFinite && value.rounded() == value
        case let ("number", .number(value)): value.isFinite
        default: false
        }
    }

    private static func equal(_ lhs: EditorCloudValue, _ rhs: EditorCloudValue) -> Bool {
        switch (lhs, rhs) {
        case let (.object(left), .object(right)):
            return left.count == right.count && left.allSatisfy { pair in right[pair.key].map { equal(pair.value, $0) } == true }
        case let (.array(left), .array(right)):
            return left.count == right.count && zip(left, right).allSatisfy { equal($0.0, $0.1) }
        case let (.integer(left), .number(right)), let (.number(right), .integer(left)):
            return Int64(exactly: right) == left
        default: return lhs == rhs
        }
    }

    private static func number(_ value: EditorCloudValue) -> Decimal? {
        switch value {
        case let .integer(amount): Decimal(amount)
        case let .number(amount) where amount.isFinite: Decimal(string: String(amount), locale: Locale(identifier: "en_US_POSIX"))
        default: nil
        }
    }

    private static func allowedCount(_ count: Int, _ minimum: EditorCloudValue, _ maximum: EditorCloudValue) -> Bool {
        Int64(count) >= (minimum.int ?? 0) && Int64(count) <= (maximum.int ?? .max)
    }

    private static func stringList(_ value: EditorCloudValue) -> [String]? {
        guard case let .array(entries) = value else { return nil }
        let names = entries.compactMap(\.string)
        return names.count == entries.count ? names : nil
    }

    static func isBounded(_ value: EditorCloudValue, remaining: Int, depth: Int) -> Bool {
        var budget = remaining
        return spend(value, budget: &budget, depth: depth)
    }

    private static func spend(_ value: EditorCloudValue, budget: inout Int, depth: Int) -> Bool {
        guard budget > 0, depth < 18 else { return false }
        budget -= 8
        switch value {
        case let .object(fields):
            for (key, child) in fields {
                budget -= key.utf8.count
                guard spend(child, budget: &budget, depth: depth + 1) else { return false }
            }
        case let .array(children):
            for child in children {
                guard spend(child, budget: &budget, depth: depth + 1) else { return false }
            }
        case let .string(text): budget -= text.utf8.count
        default: break
        }
        return budget >= 0
    }

    enum Failure: LocalizedError {
        case schema, arguments

        var errorDescription: String? {
            switch self {
            case .schema: "Studio cannot validate this MCP tool's input schema."
            case .arguments: "The tool arguments do not match the MCP input schema."
            }
        }
    }
}
