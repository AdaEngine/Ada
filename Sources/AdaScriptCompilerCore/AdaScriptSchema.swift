extension Parser {
    mutating func parse() throws -> Output {
        var output = Output()
        while !isAtEnd {
            let annotations = try parseAnnotations()
            if match("class") {
                try parseClass(annotations: annotations, output: &output)
                continue
            }
            if match("struct") {
                try parseStruct(annotations: annotations, output: &output)
                continue
            }
            if match("func") {
                if let rpc = annotations.first(where: { $0.name == "rpc" }) {
                    guard annotations.count == 1 else {
                        throw error("@rpc cannot be combined with other declaration annotations")
                    }
                    let parsed = try parseRPCFunction(annotation: rpc)
                    guard !parsed.hasBody else {
                        throw error("@rpc method bodies must be declared inside an @system class")
                    }
                    output.networkCommands.append(parsed.schema)
                } else {
                    try skipFunctionDeclaration()
                }
                continue
            }
            advance()
        }
        return output
    }

    private mutating func parseClass(annotations: [Annotation], output: inout Output) throws {
        let declarationLine = current?.line ?? 1
        guard let name = consumeIdentifier() else {
            throw error("expected class name")
        }
        if let annotation = annotations.first(where: { ["component", "replicated_component", "resource", "network_command"].contains($0.name) }) {
            throw error("@\(annotation.name) on \(name) requires a struct; change 'class' to 'struct'")
        }
        let viewAnnotation = annotations.first(where: { $0.name == "view" })
        let toolAnnotations = annotations.filter { $0.name == "tool" }
        let previewAnnotations = annotations.filter { $0.name == "previewable" }
        guard toolAnnotations.count <= 1 else {
            throw error("@tool can only be applied once to \(name)")
        }
        guard toolAnnotations.isEmpty || annotations.allSatisfy({ $0.name == "tool" }) else {
            throw error("@tool cannot be combined with other declaration annotations on \(name)")
        }
        guard previewAnnotations.count <= 1 else {
            throw error("@previewable can only be applied once to \(name)")
        }
        guard previewAnnotations.isEmpty || viewAnnotation != nil else {
            throw error("@previewable can only annotate an @view declaration")
        }
        let declarationAnnotations = annotations.filter { ["tool", "system", "scriptable", "view"].contains($0.name) }
        guard declarationAnnotations.count <= 1 else {
            throw error("\(declarationAnnotations.map { "@\($0.name)" }.joined(separator: " and ")) cannot be combined on \(name)")
        }

        if let toolAnnotation = toolAnnotations.first {
            output.tools.append(try parseTool(name: name, annotation: toolAnnotation, line: declarationLine))
            try skipDeclarationBody()
        } else if annotations.contains(where: { $0.name == "system" }) {
            let system = try parseSystemBody(systemName: name)
            output.resourceBindings += system.resourceBindings
            output.remoteCommandBindings += system.remoteCommandBindings
            output.networkCommands += system.networkCommands
            output.rpcMethodBindings += system.rpcMethodBindings
            output.systemCapabilities.append(system.capabilities)
        } else if let annotation = annotations.first(where: { $0.name == "scriptable" }) {
            output.scriptables.append(try parseScriptable(name: name, annotation: annotation))
        } else if let viewAnnotation {
            output.views.append(
                try parseView(
                    name: name,
                    annotation: viewAnnotation,
                    previewAnnotation: previewAnnotations.first,
                    line: declarationLine
                )
            )
        } else {
            try skipDeclarationBody()
        }
    }

    private mutating func parseStruct(annotations: [Annotation], output: inout Output) throws {
        let declarationLine = current?.line ?? 1
        guard let name = consumeIdentifier() else {
            throw error("expected struct name")
        }
        if let annotation = annotations.first(where: { ["system", "scriptable", "tool"].contains($0.name) }) {
            throw error("@\(annotation.name) on \(name) requires a class; change 'struct' to 'class'")
        }
        let viewAnnotations = annotations.filter { $0.name == "view" }
        let previewAnnotations = annotations.filter { $0.name == "previewable" }
        guard viewAnnotations.count <= 1, previewAnnotations.count <= 1 else {
            throw error("@view and @previewable can only be applied once to \(name)")
        }
        guard previewAnnotations.isEmpty || !viewAnnotations.isEmpty else {
            throw error("@previewable can only annotate an @view declaration")
        }
        if let viewAnnotation = viewAnnotations.first {
            guard annotations.count == 1 + previewAnnotations.count else {
                throw error("@view cannot be combined with data annotations on \(name)")
            }
            output.views.append(try parseView(name: name, annotation: viewAnnotation, previewAnnotation: previewAnnotations.first, line: declarationLine))
            return
        }
        if let commandAnnotation = annotations.first(where: { $0.name == "network_command" }) {
            guard annotations.count == 1 else {
                throw error("@network_command cannot be combined with other declaration annotations on \(name)")
            }
            output.networkCommands.append(try parseNetworkCommand(name: name, annotation: commandAnnotation))
            return
        }
        guard let schemaAnnotation = annotations.first(where: {
            $0.name == "component" || $0.name == "replicated_component" || $0.name == "resource"
        }) else {
            try skipDeclarationBody()
            return
        }
        guard annotations.count == 1 else {
            throw error("@\(schemaAnnotation.name) cannot be combined with other declaration annotations on \(name)")
        }
        output.schemas.append(try parseSchema(name: name, annotation: schemaAnnotation))
    }
}

extension Parser {
    private mutating func parseView(
        name _: String,
        annotation _: Annotation,
        previewAnnotation _: Annotation?,
        line _: Int
    ) throws -> AdaScriptViewSchema {
        throw error("AdaUI views in AdaScript are temporarily unavailable.")
    }

    private mutating func parseScriptable(name: String, annotation: Annotation) throws -> AdaScriptableSchema {
        let body = try parseScriptableBody(name: name)
        return AdaScriptableSchema(
            aliases: try scriptableAliases(annotation),
            bindings: body.bindings,
            fields: body.fields,
            id: try scriptableID(name: name, annotation: annotation),
            name: name,
            sourcePath: path,
            version: scriptableVersion(annotation)
        )
    }

    private mutating func parseScriptableBody(
        name: String
    ) throws -> (bindings: [AdaScriptableBinding], fields: [AdaScriptSchemaField]) {
        guard match("{") else {
            throw error("expected '{' after scriptable \(name)")
        }
        var depth = 1
        var bindings: [AdaScriptableBinding] = []
        var fields: [AdaScriptSchemaField] = []
        var fieldNames = Set<String>()
        while !isAtEnd, depth > 0 {
            if depth == 1 {
                let annotations = try parseAnnotations()
                if annotations.contains(where: { $0.name == "export" }) {
                    let field = try parseScriptableField(declarationName: name)
                    guard fieldNames.insert(field.name).inserted else {
                        throw error("duplicate field '\(field.name)' in \(name)")
                    }
                    fields.append(field)
                    continue
                }
                if let bindingAnnotation = annotations.first(where: { $0.name == "component" || $0.name == "res" }) {
                    bindings.append(try parseScriptableBinding(annotation: bindingAnnotation, declarationName: name))
                    continue
                }
            }
            advanceSystemBody(depth: &depth)
        }
        guard depth == 0 else {
            throw error("unterminated scriptable declaration '\(name)'")
        }
        return (bindings, fields)
    }

    private func scriptableID(name: String, annotation: Annotation) throws -> String {
        guard case let .string(id) = annotation.arguments["id"] else {
            throw error("@scriptable on \(name) requires id: \"...\"")
        }
        return id
    }

    private func scriptableVersion(_ annotation: Annotation) -> Int {
        if case let .number(value) = annotation.arguments["version"], let parsed = Int(value), parsed > 0 {
            return parsed
        }
        return 1
    }

    private func scriptableAliases(_ annotation: Annotation) throws -> [String] {
        if case let .list(values) = annotation.arguments["aliases"] {
            return try values.map { value in
                guard case let .string(alias) = value else {
                    throw error("@scriptable aliases must contain strings")
                }
                return alias
            }
        }
        return []
    }

    private mutating func parseScriptableBinding(
        annotation: Annotation,
        declarationName: String
    ) throws -> AdaScriptableBinding {
        guard
            match("var"), let propertyName = consumeIdentifier(), match(":"),
            let typeName = consumeIdentifier(), match(";")
        else {
            throw error("@\(annotation.name) in \(declarationName) must annotate 'var name: Type;'")
        }
        if annotation.name == "component" {
            let required: Bool
            if case let .bool(value) = annotation.arguments["required"] {
                required = value
            } else {
                required = false
            }
            return AdaScriptableBinding(
                kind: .component(required: required),
                propertyName: propertyName,
                typeName: typeName
            )
        }
        let optional: Bool
        if case let .bool(value) = annotation.arguments["optional"] {
            optional = value
        } else {
            optional = false
        }
        return AdaScriptableBinding(
            kind: .resource(optional: optional),
            propertyName: propertyName,
            typeName: typeName
        )
    }

    private mutating func parseScriptableField(declarationName: String) throws -> AdaScriptSchemaField {
        guard match("var"), let fieldName = consumeIdentifier() else {
            throw error("@export in \(declarationName) must annotate a stored var")
        }
        if match(":") {
            guard consumeIdentifier() != nil else {
                throw error("expected field type for \(fieldName)")
            }
        }
        guard match("=") else {
            throw error("field '\(fieldName)' requires a constant default")
        }
        let defaultValue = try parseFieldValue(fieldName: fieldName)
        guard match(";") else {
            throw error("expected ';' after field '\(fieldName)'")
        }
        return AdaScriptSchemaField(defaultValue: defaultValue, name: fieldName)
    }

    private mutating func parseSystemBody(
        systemName: String
    ) throws -> (
        resourceBindings: [AdaScriptResourceBinding],
        remoteCommandBindings: [AdaScriptRemoteCommandBinding],
        networkCommands: [AdaScriptNetworkCommandSchema],
        rpcMethodBindings: [AdaScriptRPCMethodBinding],
        capabilities: AdaScriptSystemCapabilities
    ) {
        guard match("{") else {
            throw error("expected '{' after system \(systemName)")
        }
        var bindings: [AdaScriptResourceBinding] = []
        var remoteCommandBindings: [AdaScriptRemoteCommandBinding] = []
        var networkCommands: [AdaScriptNetworkCommandSchema] = []
        var rpcMethodBindings: [AdaScriptRPCMethodBinding] = []
        var depth = 1
        var usesDeferredCommands = false
        while !isAtEnd, depth > 0 {
            usesDeferredCommands =
                usesDeferredCommands
                || checkSequence(["context", ".", "world", ".", "commands"])
                || checkSequence(["context", ".", "world", ".", "spawn"])
            if depth == 1 {
                let annotations = try parseAnnotations()
                if let rpc = annotations.first(where: { $0.name == "rpc" }) {
                    guard annotations.count == 1, match("func") else {
                        throw error("@rpc in \(systemName) must annotate a method")
                    }
                    let parsed = try parseRPCFunction(annotation: rpc)
                    networkCommands.append(parsed.schema)
                    if parsed.hasBody {
                        rpcMethodBindings.append(AdaScriptRPCMethodBinding(
                            commandName: parsed.schema.name,
                            fieldNames: parsed.schema.fields.map(\.name),
                            systemName: systemName
                        ))
                    }
                    continue
                }
                let parsedBindings = try parseSystemBindings(systemName: systemName, annotations: annotations)
                if let resource = parsedBindings.resource {
                    bindings.append(resource)
                    continue
                }
                if let remoteCommands = parsedBindings.remoteCommands {
                    remoteCommandBindings.append(remoteCommands)
                    continue
                }
            }
            advanceSystemBody(depth: &depth)
        }
        guard depth == 0 else {
            throw error("unterminated system declaration '\(systemName)'")
        }
        return (
            bindings,
            remoteCommandBindings,
            networkCommands,
            rpcMethodBindings,
            AdaScriptSystemCapabilities(
                systemName: systemName,
                usesDeferredCommands: usesDeferredCommands
            )
        )
    }

    private mutating func parseSystemBindings(
        systemName: String,
        annotations: [Annotation]
    ) throws -> (resource: AdaScriptResourceBinding?, remoteCommands: AdaScriptRemoteCommandBinding?) {
        if let remoteCommands = annotations.first(where: { $0.name == "remote_commands" }) {
            guard
                annotations.count == 1,
                case let .identifier(commandName)? = remoteCommands.positionalArguments.first,
                remoteCommands.positionalArguments.count == 1,
                remoteCommands.arguments.isEmpty,
                match("var"), let propertyName = consumeIdentifier(), match(";")
            else {
                throw error("@remote_commands in \(systemName) must annotate 'var name;' and name one command type")
            }
            return (
                nil,
                AdaScriptRemoteCommandBinding(
                    commandName: commandName,
                    propertyName: propertyName,
                    systemName: systemName
                )
            )
        }
        guard let resourceAnnotation = annotations.first(where: { $0.name == "res" }) else {
            return (nil, nil)
        }
        guard
            match("var"), let propertyName = consumeIdentifier(), match(":"),
            let resourceName = consumeIdentifier(), match(";")
        else {
            throw error("@res in \(systemName) must annotate 'var name: ResourceType;'")
        }
        let isOptional: Bool
        if case let .bool(value) = resourceAnnotation.arguments["optional"] {
            isOptional = value
        } else {
            isOptional = false
        }
        return (
            AdaScriptResourceBinding(
                isOptional: isOptional,
                propertyName: propertyName,
                resourceName: resourceName,
                systemName: systemName
            ),
            nil
        )
    }

    private mutating func advanceSystemBody(depth: inout Int) {
        if match("{") {
            depth += 1
        } else if match("}") {
            depth -= 1
        } else {
            advance()
        }
    }

    private mutating func parseSchema(name: String, annotation: Annotation) throws -> AdaScriptDataSchema {
        guard match("{") else {
            throw error("expected '{' after \(name)")
        }
        let fields = try parseFields(
            declarationName: name,
            networkDeclaration: annotation.name == "replicated_component"
        )
        guard match("}") else {
            throw error("unterminated data declaration '\(name)'")
        }
        guard !fields.isEmpty else {
            throw error("@\(annotation.name) \(name) requires at least one @export field")
        }
        return AdaScriptDataSchema(
            fields: fields,
            id: try schemaID(name: name, annotation: annotation),
            kind: schemaKind(annotation),
            name: name,
            replication: try replicatedComponentSchema(annotation),
            sourcePath: path
        )
    }

    private mutating func parseFields(
        declarationName: String,
        networkDeclaration: Bool
    ) throws -> [AdaScriptSchemaField] {
        var fields: [AdaScriptSchemaField] = []
        var fieldNames = Set<String>()
        var networkTags = Set<UInt16>()
        while !isAtEnd, !check("}") {
            let annotations = try parseAnnotations()
            guard match("var") else {
                advance()
                continue
            }
            guard let fieldName = consumeIdentifier() else {
                throw error("expected field name in \(declarationName)")
            }
            if match(":") {
                guard consumeIdentifier() != nil else {
                    throw error("expected field type for \(fieldName)")
                }
            }
            guard match("=") else {
                throw error("field '\(fieldName)' requires a constant default")
            }
            let defaultValue = try parseFieldValue(fieldName: fieldName)
            guard match(";") else {
                throw error("expected ';' after field '\(fieldName)'")
            }
            let networkAnnotation = annotations.first(where: { $0.name == "network_field" })
            let isLocal = annotations.contains(where: { $0.name == "local" })
            if networkAnnotation != nil && isLocal {
                throw error("field '\(fieldName)' cannot be both @network_field and @local")
            }
            guard networkDeclaration || annotations.contains(where: { $0.name == "export" }) else {
                continue
            }
            guard fieldNames.insert(fieldName).inserted else {
                throw error("duplicate field '\(fieldName)' in \(declarationName)")
            }
            let network = try networkAnnotation.map { try parseNetworkField($0, fieldName: fieldName) }
            if let network, !networkTags.insert(network.tag).inserted {
                throw error("duplicate network field tag \(network.tag) in \(declarationName)")
            }
            fields.append(AdaScriptSchemaField(defaultValue: defaultValue, name: fieldName, network: network))
        }
        return fields
    }

    private func schemaID(name: String, annotation: Annotation) throws -> String {
        if case let .string(explicitID) = annotation.arguments["id"] {
            return explicitID
        }
        throw error("@\(annotation.name) on \(name) requires id: \"...\"")
    }

    private func schemaKind(_ annotation: Annotation) -> AdaScriptDataSchema.Kind {
        if annotation.name == "component" || annotation.name == "replicated_component" {
            return .component
        }
        if case let .bool(value) = annotation.arguments["autoInsert"] {
            return .resource(autoInsert: value)
        }
        return .resource(autoInsert: false)
    }

    private func replicatedComponentSchema(_ annotation: Annotation) throws -> AdaScriptReplicatedComponentSchema? {
        guard annotation.name == "replicated_component" else {
            return nil
        }
        let allowed = Set(["id", "version", "authority", "visibility"])
        guard annotation.positionalArguments.isEmpty, annotation.arguments.keys.allSatisfy(allowed.contains) else {
            throw error("@replicated_component supports id, version, authority, and visibility")
        }
        let authority = try annotationString(annotation, key: "authority", default: "host")
        let visibility = try annotationString(annotation, key: "visibility", default: "all_peers")
        guard ["host", "any_peer"].contains(authority), visibility == "all_peers" else {
            throw error("@replicated_component has unsupported authority or visibility")
        }
        return AdaScriptReplicatedComponentSchema(
            authority: authority,
            version: try annotationPositiveInt(annotation, key: "version", default: 1),
            visibility: visibility
        )
    }

    private mutating func parseNetworkCommand(
        name: String,
        annotation: Annotation
    ) throws -> AdaScriptNetworkCommandSchema {
        guard match("{") else {
            throw error("expected '{' after \(name)")
        }
        let fields = try parseFields(declarationName: name, networkDeclaration: true)
        guard match("}") else {
            throw error("unterminated network command declaration '\(name)'")
        }
        guard !fields.isEmpty, fields.allSatisfy({ $0.network != nil }) else {
            throw error("@network_command \(name) requires every field to use @network_field")
        }
        return try makeNetworkCommand(name: name, fields: fields, annotation: annotation)
    }

    private mutating func parseRPCFunction(annotation: Annotation) throws -> (schema: AdaScriptNetworkCommandSchema, hasBody: Bool) {
        guard let name = consumeIdentifier(), match("(") else {
            throw error("@rpc must annotate a function with parameters")
        }
        var fields: [AdaScriptSchemaField] = []
        var tags = Set<UInt16>()
        while !isAtEnd, !check(")") {
            let annotations = try parseAnnotations()
            guard
                annotations.count == 1,
                let network = annotations.first,
                network.name == "network_field",
                let fieldName = consumeIdentifier()
            else {
                throw error("@rpc \(name) requires @network_field on every parameter")
            }
            if match(":") {
                guard consumeIdentifier() != nil else {
                    throw error("@rpc \(name) parameter '\(fieldName)' has no type")
                }
            }
            guard match("=") else {
                throw error("@rpc \(name) parameter '\(fieldName)' requires a constant default")
            }
            let defaultValue = try parseFieldValue(fieldName: fieldName)
            let networkField = try parseNetworkField(network, fieldName: fieldName)
            guard tags.insert(networkField.tag).inserted else {
                throw error("duplicate network field tag \(networkField.tag) in \(name)")
            }
            fields.append(AdaScriptSchemaField(defaultValue: defaultValue, name: fieldName, network: networkField))
            if !match(",") { break }
        }
        guard match(")"), !fields.isEmpty else {
            throw error("@rpc \(name) requires at least one tagged parameter")
        }
        var hasBody = false
        if match("{") {
            hasBody = !check("}")
            var depth = 1
            while !isAtEnd, depth > 0 {
                advanceSystemBody(depth: &depth)
            }
            guard depth == 0 else {
                throw error("unterminated @rpc body in \(name)")
            }
        } else {
            guard match(";") else {
                throw error("@rpc \(name) must end with ';' or an empty body")
            }
        }
        if hasBody, fields.contains(where: { $0.name == "source" }) {
            throw error("@rpc \(name) reserves 'source' for the authenticated sender")
        }
        return (try makeNetworkCommand(name: name, fields: fields, annotation: annotation), hasBody)
    }

    private func makeNetworkCommand(
        name: String,
        fields: [AdaScriptSchemaField],
        annotation: Annotation
    ) throws -> AdaScriptNetworkCommandSchema {
        let allowed = Set(["id", "version", "direction", "delivery", "channel", "maximumPayloadSize"])
        guard annotation.positionalArguments.isEmpty, annotation.arguments.keys.allSatisfy(allowed.contains) else {
            throw error("@\(annotation.name) contains an unsupported argument")
        }
        let channel = try annotationString(annotation, key: "channel", default: "command")
        let delivery = try annotationString(annotation, key: "delivery", default: "reliable_ordered")
        let direction = try annotationString(annotation, key: "direction", default: "peer_to_host")
        guard !channel.isEmpty,
            ["reliable_ordered", "unreliable", "unreliable_sequenced"].contains(delivery),
            ["peer_to_host", "host_to_peer", "bidirectional"].contains(direction)
        else {
            throw error("@\(annotation.name) has unsupported direction, delivery, or channel")
        }
        return AdaScriptNetworkCommandSchema(
            channel: channel,
            delivery: delivery,
            direction: direction,
            fields: fields,
            id: try schemaID(name: name, annotation: annotation),
            maximumPayloadSize: try annotationPositiveInt(annotation, key: "maximumPayloadSize", default: 64 * 1_024),
            name: name,
            sourcePath: path,
            version: try annotationPositiveInt(annotation, key: "version", default: 1)
        )
    }

    private func parseNetworkField(
        _ annotation: Annotation,
        fieldName: String
    ) throws -> AdaScriptNetworkFieldSchema {
        guard
            annotation.positionalArguments.count == 1,
            case let .number(tagText) = annotation.positionalArguments[0],
            let tag = UInt16(tagText),
            tag > 0,
            annotation.arguments.keys.allSatisfy({ $0 == "mode" || $0 == "interpolate" })
        else {
            throw error("@network_field on \(fieldName) requires one positive UInt16 tag")
        }
        let interpolation = try annotationString(annotation, key: "interpolate", default: "none")
        let mode = try annotationString(annotation, key: "mode", default: "state")
        guard ["none", "linear", "custom"].contains(interpolation),
            ["state", "latest", "initial_only"].contains(mode)
        else {
            throw error("@network_field on \(fieldName) has unsupported mode or interpolation")
        }
        return AdaScriptNetworkFieldSchema(
            interpolation: interpolation,
            mode: mode,
            tag: tag
        )
    }

    private func annotationString(_ annotation: Annotation, key: String, default defaultValue: String) throws -> String {
        guard let value = annotation.arguments[key] else {
            return defaultValue
        }
        switch value {
        case let .identifier(value), let .string(value):
            return value
        default:
            throw error("@\(annotation.name) \(key) must be a string or identifier")
        }
    }

    private func annotationPositiveInt(_ annotation: Annotation, key: String, default defaultValue: Int) throws -> Int {
        guard let value = annotation.arguments[key] else {
            return defaultValue
        }
        guard case let .number(text) = value, let parsed = Int(text), parsed > 0 else {
            throw error("@\(annotation.name) \(key) must be a positive integer")
        }
        return parsed
    }

    private mutating func parseFieldValue(fieldName: String) throws -> AdaScriptSchemaField.Value {
        var sign = ""
        if match("-") {
            sign = "-"
        }
        guard let token = current else {
            throw error("missing default for '\(fieldName)'")
        }
        advance()
        switch token.kind {
        case .string:
            return .string(token.text)
        case .number:
            let value = sign + token.text
            if value.contains(".") || value.lowercased().contains("e") {
                guard let number = Double(value), number.isFinite else {
                    throw error("invalid floating-point default for '\(fieldName)'")
                }
                return .double(number)
            }
            guard let number = Int64(value) else {
                throw error("invalid integer default for '\(fieldName)'")
            }
            return .int(number)
        case .identifier where token.text == "true":
            return .bool(true)
        case .identifier where token.text == "false":
            return .bool(false)
        default:
            throw error("unsupported default for '\(fieldName)'")
        }
    }

    private mutating func parseAnnotations() throws -> [Annotation] {
        var result: [Annotation] = []
        while match("@") {
            guard let name = consumeIdentifier() else {
                throw error("expected annotation name")
            }
            var arguments: [String: Literal] = [:]
            var positionalArguments: [Literal] = []
            if match("(") {
                while !isAtEnd, !check(")") {
                    if current?.kind == .identifier, checkNext(":") {
                        guard let label = consumeIdentifier(), match(":") else {
                            throw error("invalid named argument in @\(name)")
                        }
                        arguments[label] = try parseLiteral(annotation: name, label: label)
                    } else {
                        positionalArguments.append(try parseLiteral(annotation: name, label: "value"))
                    }
                    if !match(",") {
                        break
                    }
                }
                guard match(")") else {
                    throw error("unterminated @\(name) annotation")
                }
            }
            result.append(Annotation(arguments: arguments, name: name, positionalArguments: positionalArguments))
        }
        return result
    }

    private mutating func parseLiteral(annotation: String, label: String) throws -> Literal {
        if check("[") {
            return .list(try parseLiteralList(annotation: annotation, label: label))
        }
        guard let token = current else {
            throw error("missing value for @\(annotation) \(label)")
        }
        advance()
        switch token.kind {
        case .string:
            return .string(token.text)
        case .number:
            return .number(token.text)
        case .identifier where token.text == "true":
            return .bool(true)
        case .identifier where token.text == "false":
            return .bool(false)
        case .identifier:
            return .identifier(token.text)
        default:
            throw error("unsupported value for @\(annotation) \(label)")
        }
    }

    private mutating func parseLiteralList(annotation: String, label: String) throws -> [Literal] {
        _ = match("[")
        var values: [Literal] = []
        while !isAtEnd, !check("]") {
            values.append(try parseLiteral(annotation: annotation, label: label))
            if !match(",") {
                break
            }
        }
        guard match("]") else {
            throw error("unterminated list for @\(annotation) \(label)")
        }
        return values
    }

    private mutating func skipDeclarationBody() throws {
        while !isAtEnd, !check("{") { advance() }
        guard match("{") else {
            return
        }
        var depth = 1
        while !isAtEnd, depth > 0 {
            if match("{") {
                depth += 1
            } else if match("}") {
                depth -= 1
            } else {
                advance()
            }
        }
    }

    private mutating func skipFunctionDeclaration() throws {
        while !isAtEnd, !check("{"), !check(";") { advance() }
        if match(";") { return }
        try skipDeclarationBody()
    }

    private var current: Token? { tokens.indices.contains(index) ? tokens[index] : nil }
    private var isAtEnd: Bool { index >= tokens.count }

    private func check(_ text: String) -> Bool { current?.text == text }

    private func checkNext(_ text: String) -> Bool {
        let nextIndex = index + 1
        return tokens.indices.contains(nextIndex) && tokens[nextIndex].text == text
    }

    private func checkSequence(_ values: [String]) -> Bool {
        guard index + values.count <= tokens.count else {
            return false
        }
        return zip(tokens[index..<(index + values.count)], values)
            .allSatisfy { token, value in
                token.text == value
            }
    }

    @discardableResult
    private mutating func match(_ text: String) -> Bool {
        guard check(text) else {
            return false
        }
        advance()
        return true
    }

    private mutating func consumeIdentifier() -> String? {
        guard let current, current.kind == .identifier else {
            return nil
        }
        advance()
        return current.text
    }

    private mutating func advance() { index += 1 }

    private func error(_ message: String) -> AdaScriptSchemaError {
        .invalid(path: path, message: message)
    }
}
