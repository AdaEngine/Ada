import Foundation

/// A bounded, host-defined form predicate. Values are literals or ordinary named UI bindings.
public struct UIFormCheck: Codable, Hashable, Sendable {
    public enum Function: String, Codable, Sendable { case required, range }
    public var function: Function
    public var value: UIArgument
    public var message: String
    public var minimum: Double?
    public var maximum: Double?

    public init(function: Function, value: UIArgument, message: String, minimum: Double? = nil, maximum: Double? = nil) throws {
        guard !message.isEmpty, message.utf8.count <= 1024, (value.value != nil) != (value.binding != nil) else {
            throw UIDiagnostic("A form check requires one value and a nonempty bounded message.")
        }
        if function == .range {
            guard let minimum, let maximum, minimum.isFinite, maximum.isFinite, minimum <= maximum else {
                throw UIDiagnostic("A range check requires finite ordered bounds.")
            }
        } else if minimum != nil || maximum != nil {
            throw UIDiagnostic("A required check does not accept range bounds.")
        }
        self.function = function
        self.value = value
        self.message = message
        self.minimum = minimum
        self.maximum = maximum
    }

    /// Evaluates a resolved value without executing agent-provided code.
    public func accepts(_ resolved: UIValue?) -> Bool {
        switch function {
        case .required:
            switch resolved {
            case let .string(text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case let .bool(value): value
            case let .number(value): value.isFinite
            case let .array(value): !value.isEmpty
            case let .object(value): !value.isEmpty
            default: false
            }
        case .range:
            if let number = resolved?.number, let minimum, let maximum {
                number.isFinite && (minimum...maximum).contains(number)
            } else { false }
        }
    }

    public static func decode(_ value: UIValue) throws -> [Self] {
        guard let entries = value.array, entries.count <= 32 else { throw UIDiagnostic("Expected at most 32 form checks.") }
        return try entries.map { entry in
            let decoded = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(entry))
            return try Self(function: decoded.function, value: decoded.value, message: decoded.message, minimum: decoded.minimum, maximum: decoded.maximum)
        }
    }
}
