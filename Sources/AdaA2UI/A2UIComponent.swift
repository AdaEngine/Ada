import AdaUIDescription

struct A2UIComponent {
    let id: String
    let type: String
    let properties: [String: UIValue]
    let children: [String]

    init(_ value: UIValue) throws {
        let fields = try value.objectFields()
        id = try fields.requiredString("id")
        type = try fields.requiredString("component")
        properties = fields
        let allowed: Set<String>
        switch type {
        case "Column", "Row": allowed = ["children", "spacing"]
        case "Text": allowed = ["text"]
        case "Button": allowed = ["text", "action", "checks"]
        case "TextField": allowed = ["text", "placeholder", "checks"]
        case "Toggle": allowed = ["label", "value", "checks"]
        case "ChoicePicker": allowed = ["label", "value", "options", "checks"]
        case "Slider": allowed = ["value", "min", "max", "step", "checks"]
        default: throw A2UIValidationError(path: "/component", message: "Unknown Ada catalog component '\(type)'.")
        }
        try fields.checkKeys(allowed.union(["id", "component"]))
        if type == "Column" || type == "Row" {
            guard let values = fields["children"]?.array else {
                throw A2UIValidationError(path: "/children", message: "Expected a static array of component IDs.")
            }
            children = try values.map {
                guard let child = $0.string, !child.isEmpty else {
                    throw A2UIValidationError(path: "/children", message: "Expected nonempty component IDs.")
                }
                return child
            }
            guard Set(children).count == children.count else {
                throw A2UIValidationError(path: "/children", message: "Duplicate child ID.")
            }
            if let spacing = fields["spacing"] {
                guard let number = spacing.number, number.isFinite, (0...128).contains(number) else {
                    throw A2UIValidationError(path: "/spacing", message: "Expected a number between 0 and 128.")
                }
            }
        } else {
            children = []
        }
        switch type {
        case "Text", "Button", "TextField":
            _ = try A2UIDynamicValue(fields["text"], type: .string, requiresBinding: type == "TextField")
        case "Toggle":
            _ = try A2UIDynamicValue(fields["label"], type: .string)
            _ = try A2UIDynamicValue(fields["value"], type: .bool, requiresBinding: true)
        default: break
        }
        if type == "ChoicePicker" {
            _ = try A2UIDynamicValue(fields["label"] ?? .string(""), type: .string)
            _ = try A2UIDynamicValue(fields["value"], type: .string, requiresBinding: true)
            guard let options = fields["options"]?.array, !options.isEmpty, options.count <= 64 else {
                throw A2UIValidationError(path: "/options", message: "Expected 1...64 labeled choices.")
            }
            var values = Set<String>()
            for option in options {
                let item = try option.objectFields()
                try item.checkKeys(["label", "value"])
                _ = try item.requiredString("label")
                let value = try item.requiredString("value")
                guard values.insert(value).inserted else { throw A2UIValidationError(path: "/options", message: "Choice values must be unique.") }
            }
        }
        if type == "Slider" {
            _ = try A2UIDynamicValue(fields["value"], type: .number, requiresBinding: true)
            guard let lower = fields["min"]?.number, let upper = fields["max"]?.number,
                  lower.isFinite, upper.isFinite, lower < upper, (upper - lower).isFinite else {
                throw A2UIValidationError(path: "/min", message: "Slider requires finite ordered min/max bounds.")
            }
            if let step = fields["step"] {
                guard let number = step.number, number.isFinite, number > 0 else {
                    throw A2UIValidationError(path: "/step", message: "Slider step must be a positive finite number.")
                }
            }
        }
        _ = try A2UIFormChecks(fields["checks"])
        if let placeholder = fields["placeholder"], placeholder.string == nil {
            throw A2UIValidationError(path: "/placeholder", message: "Expected a literal string.")
        }
        if type == "Button" { _ = try A2UIAction(fields["action"]) }
    }
}

struct A2UIDynamicValue {
    let literal: UIValue?
    let pointer: A2UIPointer?
    let type: UIValueType
    var fallback: UIValue {
        switch type {
        case .bool: .bool(false)
        case .number: .number(0)
        case .array: .array([])
        case .object: .object([:])
        case .any: .null
        case .string: .string("")
        }
    }

    init(_ value: UIValue?, type: UIValueType, requiresBinding: Bool = false) throws {
        self.type = type
        if case let .object(fields) = value {
            try fields.checkKeys(["path"])
            pointer = try A2UIPointer(fields.requiredString("path"))
            literal = nil
        } else if let value, type.accepts(value), !requiresBinding {
            literal = value
            pointer = nil
        } else {
            throw A2UIValidationError(message: requiresBinding ? "Expected a writable path binding." : "Expected a \(type.rawValue) literal or path binding.")
        }
    }

    func resolved(in model: UIValue) throws -> UIValue {
        let value = literal ?? pointer?.read(model) ?? fallback
        guard type.accepts(value) else {
            throw A2UIValidationError(path: pointer?.path ?? "/", message: "Bound value has the wrong type; expected \(type.rawValue).")
        }
        return value
    }
}

struct A2UIAction {
    let name: String
    let context: [String: UIValue]

    init(_ value: UIValue?) throws {
        guard let value else { throw A2UIValidationError(path: "/action", message: "Button requires a server event action.") }
        let action = try value.objectFields()
        try action.checkKeys(["event"])
        let event = try action["event"]?.objectFields() ?? [:]
        try event.checkKeys(["name", "context"])
        name = try event.requiredString("name")
        context = try event["context"]?.objectFields() ?? [:]
        for value in context.values {
            if case let .object(fields) = value, fields["path"] != nil {
                try fields.checkKeys(["path"])
                _ = try A2UIPointer(fields.requiredString("path"))
            }
        }
    }

    func resolve(in model: UIValue) throws -> UIValue {
        .object(try context.mapValues { value in
            if case let .object(fields) = value, let path = fields["path"]?.string {
                return try A2UIPointer(path).read(model) ?? .null
            }
            return value
        })
    }
}
