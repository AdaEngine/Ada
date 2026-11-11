import Foundation

struct EditorCloudToolCatalog: Decodable, Sendable {
    static let currentVersion = 2

    enum Host: String, Sendable {
        case desktop, mobile
    }

    struct Family: Decodable, Sendable {
        let name: String
        let description: String
        let actions: [Action]
    }

    struct Action: Decodable, Sendable {
        let name: String
        let description: String
        let bindings: [String: String]
        let plan: Bool
        let approval: Bool
        let approvals: [String: Bool]?
        let vision: Bool?
        let schema: EditorCloudValue
        let schemas: [String: EditorCloudValue]?

        func schema(for host: Host) -> EditorCloudValue { schemas?[host.rawValue] ?? schema }
        func approval(for host: Host) -> Bool { approvals?[host.rawValue] ?? approval }
    }

    struct Call: Sendable {
        let key: String
        let legacyName: String
        let approval: Bool
        let arguments: [String: EditorCloudValue]

        var target: String? {
            arguments["destination"]?.string ?? arguments["previewPath"]?.string ?? arguments["scenePath"]?.string ?? arguments["path"]?.string
        }

        func legacyArguments() throws -> EditorCloudValue {
            var payload = arguments
            if key.hasPrefix("editor_animation/") {
                payload["action"] = .string(String(legacyName.dropFirst("editor_animation_".count)))
                return ["requestJSON": .string(try Self.encode(.object(payload)))]
            }
            switch key {
            case "editor_project/configure":
                let inputActions = payload.removeValue(forKey: "encodedInputActions")
                payload["inputActions"] = inputActions
                return ["settingsJSON": .string(try Self.encode(.object(payload)))]
            case "editor_scene/list":
                payload.removeValue(forKey: "scope")
            case "editor_scene/apply":
                if let operations = payload["operations"]?.array {
                    payload["operations"] = .array(operations.map { operation in
                        guard operation["children"].string == "delete" else {
                            return operation
                        }
                        var normalized = operation
                        normalized["children"] = "cascade"
                        return normalized
                    })
                }
            default:
                break
            }
            return .object(payload)
        }

        func result(_ raw: String, host: Host) throws -> String {
            if key == "editor_files/read" {
                return try Self.encode(["path": arguments["path"] ?? .null, "content": .string(raw)])
            }
            if key == "editor_files/list" {
                return try Self.encode(["paths": .array(raw.split(separator: "\n").map { .string(String($0)) })])
            }
            if key == "editor_files/create" || key == "editor_files/patch" {
                return try Self.encode(["path": arguments["path"] ?? .null, "saved": true])
            }
            var value = Self.decode(raw)
            // Desktop authoring wraps tool payloads in an MCP text result.
            if let content = value?["content"].array.first?["text"].string {
                value = Self.decode(content) ?? .string(content)
            }
            guard var value else {
                return raw
            }
            switch key {
            case "editor_project/context":
                if let name = value["project"].string {
                    value["project"] = ["name": .string(name)]
                } else if case .object = value["project"] {
                    let configuration = value["project"]
                    value["project"] = configuration["project"]
                    value["configuration"] = configuration
                }
            case "editor_scene/list":
                value["scope"] = arguments["scope"] ?? .null
                value["scenes"] = .array(value["scenes"].array.map { scene in
                    scene.string.map { ["path": .string($0)] } ?? scene
                })
            case "editor_task/build":
                value["state"] = host == .desktop ? "started" : "completed"
                if host == .mobile { value["ok"] = true }
            case "editor_play/capture":
                value["source"] = "game_camera"
            default:
                break
            }
            return try Self.encode(value)
        }

        private static func encode(_ value: EditorCloudValue) throws -> String {
            try EditorAgentToolEncoding.string(JSONEncoder().encode(value))
        }

        private static func decode(_ text: String) -> EditorCloudValue? {
            try? JSONDecoder().decode(EditorCloudValue.self, from: Data(text.utf8))
        }
    }

    struct Selection: Sendable {
        let host: Host
        let families: [Family]

        var definitions: [EditorCloudValue] {
            families.map { family in
                [
                    "type": "function", "function": [
                        "name": .string(family.name), "description": .string(family.description),
                        "parameters": [
                            "type": "object", "required": ["action", "arguments"], "additionalProperties": false,
                            "properties": [
                                "action": ["type": "string", "enum": .array(family.actions.map { .string($0.name) })],
                                "arguments": ["type": "object"]
                            ],
                            "oneOf": .array(family.actions.map { action in
                                [
                                    "description": .string(action.description), "properties": [
                                        "action": ["enum": [.string(action.name)]], "arguments": action.schema(for: host)
                                    ]
                                ]
                            })
                        ]
                    ]
                ]
            }
        }

        var guidance: String {
            let aliases = families.flatMap { family in
                family.actions.compactMap { action in
                    action.bindings[host.rawValue].map { "\($0)=\(family.name)/\(action.name)" }
                }
            }
            return """
                Use the advertised tool family with {action, arguments}. In shared skills, files.read and files.list are editor_files/read and editor_files/list.
                For files.write use editor_files/create for new files and editor_files/patch for existing files.
                The following aliases translate legacy workflow names. Dot and underscore spellings are equivalent.
                \(aliases.joined(separator: ", "))
                """
        }

        func resolve(name: String, input: EditorCloudValue) throws -> Call {
            let family = families.first { $0.name == name }
            guard let action = family?.actions.first(where: { $0.name == input["action"].string }),
                  let binding = action.bindings[host.rawValue] else {
                throw EditorAgentServiceError.providerFailure("Tool action is unavailable in this mode.")
            }
            guard input.object.count == 2, case let .object(arguments) = input["arguments"],
                  EditorCloudToolSchema.accepts(input["arguments"], schema: action.schema(for: host)) else {
                throw EditorAgentServiceError.providerFailure("Invalid arguments for \(name)/\(action.name). Check the action schema.")
            }
            return Call(key: name + "/" + action.name, legacyName: binding, approval: action.approval(for: host), arguments: arguments)
        }
    }

    let version: Int
    let families: [Family]

    static func load() throws -> Self {
        guard let url = Bundle.editor.url(forResource: "AdaAIToolContract", withExtension: "json", subdirectory: "Assets") else {
            throw EditorAIError.invalidResponse
        }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard catalog.version == currentVersion else { throw EditorAIError.invalidResponse }
        return catalog
    }

    func selection(host: Host, planning: Bool) -> Selection {
        let supported = families.compactMap { family -> Family? in
            let actions = family.actions.filter {
                $0.bindings[host.rawValue] != nil && (!planning || $0.plan) && $0.vision != true
            }
            return actions.isEmpty ? nil : Family(name: family.name, description: family.description, actions: actions)
        }
        return Selection(host: host, families: supported)
    }
}

private enum EditorCloudToolSchema {
    static func accepts(_ value: EditorCloudValue, schema: EditorCloudValue) -> Bool {
        if case let .array(variants) = schema["oneOf"], variants.filter({ accepts(value, schema: $0) }).count != 1 {
            return false
        }
        if case let .array(values) = schema["enum"], !values.contains(value) {
            return false
        }
        if let constant = schema.object["const"], constant != value {
            return false
        }
        let types = schema["type"].string.map { [$0] } ?? schema["type"].array.compactMap(\.string)
        switch value {
        case let .object(fields):
            guard types.isEmpty || types.contains("object"),
                  schema["required"].array.compactMap(\.string).allSatisfy({ fields[$0] != nil }) else {
                return false
            }
            return fields.allSatisfy { key, child in
                if let spec = schema["properties"].object[key] {
                    return accepts(child, schema: spec)
                }
                if case .object = schema["additionalProperties"] {
                    return accepts(child, schema: schema["additionalProperties"])
                }
                return schema["additionalProperties"].bool != false
            }
        case let .array(values):
            guard types.isEmpty || types.contains("array"),
                  values.count >= (schema["minItems"].int ?? 0), values.count <= (schema["maxItems"].int ?? .max) else {
                return false
            }
            if schema["uniqueItems"].bool == true {
                for (index, item) in values.enumerated() where values.prefix(index).contains(item) {
                    return false
                }
            }
            return values.allSatisfy { accepts($0, schema: schema["items"]) }
        case let .string(text):
            guard types.isEmpty || types.contains("string"),
                  text.unicodeScalars.count >= (schema["minLength"].int ?? 0),
                  text.unicodeScalars.count <= (schema["maxLength"].int ?? .max) else {
                return false
            }
            return schema["pattern"].string.map { text.range(of: $0, options: .regularExpression) != nil } ?? true
        case .integer, .number:
            guard types.isEmpty || types.contains("number") || (types.contains("integer") && value.int != nil) else {
                return false
            }
            let number = value.seconds
            return number.isFinite
                && number >= (schema.object["minimum"]?.seconds ?? -.infinity)
                && number <= (schema.object["maximum"]?.seconds ?? .infinity)
                && number > (schema.object["exclusiveMinimum"]?.seconds ?? -.infinity)
                && number < (schema.object["exclusiveMaximum"]?.seconds ?? .infinity)
        case .bool:
            return types.isEmpty || types.contains("boolean")
        case .null:
            return types.isEmpty || types.contains("null")
        }
    }
}
