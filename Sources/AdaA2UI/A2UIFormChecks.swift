import AdaUIDescription
import Foundation

/// Deliberately small registered-function subset; no executable or recursive expressions.
struct A2UIFormChecks {
    struct Check {
        let function: UIFormCheck.Function
        let value: A2UIDynamicValue
        let message: String
        let minimum: Double?
        let maximum: Double?
    }
    let checks: [Check]
    init(_ raw: UIValue?) throws {
        guard let raw else {
            checks = []
            return
        }
        guard let entries = raw.array, entries.count <= 32 else {
            throw A2UIValidationError(path: "/checks", message: "Expected at most 32 checks.")
        }
        checks = try entries.map { entry in
            let fields = try entry.objectFields()
            try fields.checkKeys(["condition", "message"])
            let condition = try fields["condition"]?.objectFields() ?? [:]
            try condition.checkKeys(["call", "args"])
            let call = try condition.requiredString("call")
            guard let function = UIFormCheck.Function(rawValue: call) else {
                throw A2UIValidationError(path: "/checks", message: "Supported checks are required and range.")
            }
            let args = try condition["args"]?.objectFields() ?? [:]
            try args.checkKeys(function == .required ? ["value"] : ["value", "min", "max"])
            let value = try A2UIDynamicValue(args["value"], type: function == .range ? .number : .any)
            let message = try fields.requiredString("message")
            let minimum = args["min"]?.number, maximum = args["max"]?.number
            _ = try UIFormCheck(function: function, value: .init(value: .null), message: message, minimum: minimum, maximum: maximum)
            return Check(function: function, value: value, message: message, minimum: minimum, maximum: maximum)
        }
    }
    func accepts(_ model: UIValue) -> Bool {
        checks.allSatisfy { check in
            guard let value = try? check.value.resolved(in: model),
                  let rule = try? UIFormCheck(
                    function: check.function,
                    value: .init(value: value),
                    message: check.message,
                    minimum: check.minimum,
                    maximum: check.maximum
                  ) else { return false }
            return rule.accepts(value)
        }
    }
    func compiled(bindings: inout [String: A2UIDynamicValue]) throws -> UIValue {
        let rules = try checks.map { check in
            let argument: UIArgument
            if let pointer = check.value.pointer {
                if let existing = bindings[pointer.bindingName], existing.type != .any, check.value.type != .any, existing.type != check.value.type {
                    throw A2UIValidationError(path: pointer.path, message: "A check references an incompatible binding type.")
                }
                if bindings[pointer.bindingName] == nil { bindings[pointer.bindingName] = check.value }
                argument = .init(binding: pointer.bindingName)
            } else { argument = .init(value: check.value.literal ?? check.value.fallback) }
            return try UIFormCheck(function: check.function, value: argument, message: check.message, minimum: check.minimum, maximum: check.maximum)
        }
        return try JSONDecoder().decode(UIValue.self, from: JSONEncoder().encode(rules))
    }
}
