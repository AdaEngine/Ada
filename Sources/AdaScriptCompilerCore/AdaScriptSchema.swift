import Foundation

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
            if annotations.contains(where: { $0.name == "rpc" }) { _ = match("async") }
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
            let body = try parseScriptableBody(name: name)
            guard body.bindings.isEmpty else {
                throw error("@tool fields cannot bind gameplay components or resources")
            }
            output.tools.append(try parseTool(name: name, annotation: toolAnnotation, line: declarationLine, fields: body.fields))
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
                    let field = try parseScriptableField(declarationName: name, annotations: annotations)
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

    private mutating func parseScriptableField(declarationName: String, annotations: [Annotation]) throws -> AdaScriptSchemaField {
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
        return AdaScriptSchemaField(defaultValue: defaultValue, name: fieldName, groupPath: try exportGroup(annotations))
    }

    private func exportGroup(_ annotations: [Annotation]) throws -> [String] {
        guard let value = annotations.first(where: { $0.name == "export" })?.arguments["group"] else { return [] }
        guard case let .string(path) = value else { throw error("@export group must be a string") }
        let names = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (1...4).contains(names.count), names.allSatisfy({ !$0.isEmpty }) else {
            throw error("@export group requires one to four nonempty '/'-separated names")
        }
        return names
    }

    private static let deferredWorldMembers: Set<String> = ["commands", "spawn", "setTileOrientation"]

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
        let bodyStart = index
        var queryProperties: [String] = []
        while !isAtEnd, depth > 0 {
            if depth == 1 {
                let annotations = try parseAnnotations()
                if annotations.contains(where: { $0.name == "query" }), check("var"), tokens.indices.contains(index + 1),
                    tokens[index + 1].kind == .identifier {
                    queryProperties.append(tokens[index + 1].text)
                }
                if let rpc = annotations.first(where: { $0.name == "rpc" }) {
                    _ = match("async")
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
        bindings = try bindings.map { try resolvingAccess(of: $0, bodyRange: bodyStart..<max(bodyStart, index - 1)) }
        let bodyOffsets = tokens[bodyStart].startOffset..<tokens[max(bodyStart, index - 1)].endOffset
        let usesDeferredCommands = worldUses.contains { use in
            bodyOffsets.contains(use.offsets.lowerBound) && Self.deferredWorldMembers.contains(use.member ?? "")
        }
        return (
            bindings,
            remoteCommandBindings,
            networkCommands,
            rpcMethodBindings,
            AdaScriptSystemCapabilities(
                systemName: systemName,
                usesDeferredCommands: usesDeferredCommands,
                queryUsage: queryProperties.map { queryUsage(of: $0, in: bodyStart..<max(bodyStart, index - 1)) }
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
        // `.write` is a placeholder until the body is scanned; an explicit value is kept in `explicitResourceAccess`.
        if let explicit = resourceAnnotation.arguments["access"] {
            guard case let .string(value) = explicit, value == "read" || value == "write" else {
                throw error("@res access must be \"read\" or \"write\"")
            }
            explicitResourceAccess["\(systemName).\(propertyName)"] = AdaScriptResourceBinding.Access(rawValue: value)
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

    /// Chooses the scheduler access for a `@res` binding.
    ///
    /// Access is `read` only when every use of the property in the system body is a field read
    /// (`name.field`, `name.available()`). Assigning a field, or any use that could alias the view
    /// (passing it, storing it, calling it), reserves write access. An explicit `access:` wins, but
    /// `"read"` is rejected when the body writes through the binding.
    private func resolvingAccess(of binding: AdaScriptResourceBinding, bodyRange: Range<Int>) throws -> AdaScriptResourceBinding {
        let inferred = inferredAccess(of: binding.propertyName, in: bodyRange)
        var access = inferred
        if let explicit = explicitResourceAccess["\(binding.systemName).\(binding.propertyName)"] {
            if explicit == .read, inferred == .write {
                throw error("@res '\(binding.propertyName)' in \(binding.systemName) is declared access: \"read\" but is written or aliased in the system body")
            }
            access = explicit
        }
        return AdaScriptResourceBinding(
            access: access,
            isOptional: binding.isOptional,
            propertyName: binding.propertyName,
            resourceName: binding.resourceName,
            systemName: binding.systemName
        )
    }

    private func inferredAccess(of property: String, in range: Range<Int>) -> AdaScriptResourceBinding.Access {
        var cursor = range.lowerBound
        let compoundOperators: Set<String> = ["+", "-", "*", "/", "%", "&", "|", "^"]
        while cursor < range.upperBound {
            defer { cursor += 1 }
            let token = tokens[cursor]
            guard token.kind == .identifier, token.text == property else {
                continue
            }
            // Skip the declaration `var name: Type;`.
            if cursor > 0, tokens[cursor - 1].text == "var" {
                continue
            }
            // A member of some other object (`other.name`) is not the binding, except `self.name`.
            if cursor > 1, tokens[cursor - 1].text == ".", tokens[cursor - 2].text != "self" {
                continue
            }
            guard cursor + 2 < tokens.count, tokens[cursor + 1].text == ".", tokens[cursor + 2].kind == .identifier else {
                return .write
            }
            let after = cursor + 3
            guard after < tokens.count else {
                return .read
            }
            let next = tokens[after].text
            if next == "(" {
                if tokens[cursor + 2].text == "available" { continue }
                return .write
            }
            let isEqualsNotComparison = next == "=" && !(after + 1 < tokens.count && tokens[after + 1].text == "=")
            let isCompound = compoundOperators.contains(next) && after + 1 < tokens.count && tokens[after + 1].text == "="
                && tokens[after].endOffset == tokens[after + 1].startOffset
            if isEqualsNotComparison || isCompound {
                return .write
            }
        }
        return .read
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
            aliases: try schemaAliases(name: name, annotation: annotation),
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
            var declaredType: String?
            if match(":") {
                guard let typeName = consumeIdentifier() else {
                    throw error("expected field type for \(fieldName)")
                }
                declaredType = typeName
            }
            guard match("=") else {
                throw error("field '\(fieldName)' requires a constant default")
            }
            let defaultValue = try parseFieldValue(fieldName: fieldName, declaredType: declaredType)
            if networkDeclaration, !defaultValue.isScalar {
                throw error("network field '\(fieldName)' in \(declarationName) supports only Bool, Int, Float and String values")
            }
            guard match(";") else {
                throw error("expected ';' after field '\(fieldName)'")
            }
            let networkAnnotation = annotations.first(where: { $0.name == "network_field" })
            if networkAnnotation != nil, !defaultValue.isScalar {
                throw error("@network_field '\(fieldName)' in \(declarationName) supports only Bool, Int, Float and String values")
            }
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
            fields.append(AdaScriptSchemaField(defaultValue: defaultValue, name: fieldName, network: network, groupPath: try exportGroup(annotations)))
        }
        return fields
    }

    private func schemaID(name: String, annotation: Annotation) throws -> String {
        if case let .string(explicitID) = annotation.arguments["id"] {
            return explicitID
        }
        throw error("@\(annotation.name) on \(name) requires id: \"...\"")
    }

    private func schemaAliases(name: String, annotation: Annotation) throws -> [String] {
        guard let value = annotation.arguments["aliases"] else {
            return []
        }
        guard case let .list(values) = value else {
            throw error("@\(annotation.name) aliases on \(name) must be a list of strings")
        }
        var aliases: [String] = []
        for value in values {
            guard case let .string(alias) = value, !alias.isEmpty else {
                throw error("@\(annotation.name) aliases on \(name) must be non-empty strings")
            }
            guard !aliases.contains(alias) else {
                throw error("@\(annotation.name) alias '\(alias)' is repeated on \(name)")
            }
            aliases.append(alias)
        }
        return aliases
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

    /// Reads the constant after the `=` the cursor just passed from the shared syntax tree, applies the declared
    /// type to it, and moves the cursor past the value.
    private mutating func parseFieldValue(fieldName: String, declaredType: String? = nil) throws -> AdaScriptSchemaField.Value {
        guard index > 0, tokens[index - 1].text == "=", let syntax = defaultsByEquals[tokens[index - 1].startOffset] else {
            throw error("missing default for '\(fieldName)'")
        }
        let value = try AdaScriptDefaultValueResolver(enums: enums, path: path)
            .resolve(syntax.value, fieldName: fieldName, declaredType: declaredType)
        while let token = current, token.startOffset < syntax.offsets.upperBound {
            advance()
        }
        return value
    }

    /// Reads the annotations at the cursor from the shared syntax tree, so a literal is parsed in one place.
    private mutating func parseAnnotations() throws -> [Annotation] {
        var result: [Annotation] = []
        while let start = current, start.text == "@" {
            guard let syntax = annotationsByOffset[start.startOffset] else {
                throw error("expected annotation name")
            }
            var arguments: [String: Literal] = [:]
            var positionalArguments: [Literal] = []
            for argument in syntax.values {
                if let label = argument.label {
                    if syntax.name == "query", !["optional", "with", "without", "changed", "added"].contains(label) {
                        let hint = label == "where" ? "; boolean predicates are not supported yet" : ""
                        throw error("@query does not support '\(label):'\(hint). Supported clauses: optional, with, without, changed, added")
                    }
                    arguments[label] = Literal(argument.value)
                } else {
                    positionalArguments.append(Literal(argument.value))
                }
            }
            if let problem = syntax.problem {
                throw error(problem)
            }
            result.append(Annotation(arguments: arguments, name: syntax.name, positionalArguments: positionalArguments))
            while let token = current, token.startOffset < syntax.offsets.upperBound {
                advance()
            }
        }
        return result
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


extension Parser {
    private static let assignmentOperators: Set<String> = ["+", "-", "*", "/", "%", "&", "|", "^"]

    /// Reads how `property` is used inside a system body. See ``AdaScriptQueryUsage`` for the rules.
    fileprivate func queryUsage(of property: String, in range: Range<Int>) -> AdaScriptQueryUsage {
        var reads = Set<String>()
        var writes = Set<String>()
        var isOpaque = false

        func isSelfOrBare(_ cursor: Int) -> Bool {
            // `x.property` is another object's member, `self.property` is ours.
            cursor == 0 || tokens[cursor - 1].text != "." || (cursor > 1 && tokens[cursor - 2].text == "self")
        }
        // The loop headers that iterate this query, and the variable each binds.
        var loops: [(row: String, header: Range<Int>, body: Range<Int>)] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            defer { cursor += 1 }
            guard tokens[cursor].text == "for", cursor + 1 < range.upperBound, tokens[cursor + 1].text == "(" else { continue }
            var variable = cursor + 2
            if variable < range.upperBound, ["var", "const"].contains(tokens[variable].text) { variable += 1 }
            guard variable + 2 < range.upperBound, tokens[variable].kind == .identifier, tokens[variable + 1].text == "in" else { continue }
            var collection = variable + 2
            if tokens[collection].text == "self", collection + 2 < range.upperBound, tokens[collection + 1].text == "." { collection += 2 }
            guard tokens[collection].text == property, collection + 1 < range.upperBound, tokens[collection + 1].text == ")" else { continue }
            let headerEnd = collection + 1
            var bodyRange = (headerEnd + 1)..<(headerEnd + 1)
            if headerEnd + 1 < range.upperBound, tokens[headerEnd + 1].text == "{" {
                var depth = 0
                var end = headerEnd + 1
                while end < range.upperBound {
                    if tokens[end].text == "{" { depth += 1 }
                    if tokens[end].text == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    end += 1
                }
                bodyRange = (headerEnd + 2)..<min(end, range.upperBound)
            } else {
                var end = headerEnd + 1
                while end < range.upperBound, tokens[end].text != ";" { end += 1 }
                bodyRange = (headerEnd + 1)..<min(end, range.upperBound)
            }
            loops.append((tokens[variable].text, (cursor)..<(headerEnd + 1), bodyRange))
        }

        // Any use of the query outside its own loop headers hides what is touched.
        for index in range where tokens[index].kind == .identifier && tokens[index].text == property && isSelfOrBare(index) {
            if index > 0, tokens[index - 1].text == "var" { continue }
            if loops.contains(where: { $0.header.contains(index) }) { continue }
            isOpaque = true
        }

        for loop in loops {
            for index in loop.body where tokens[index].kind == .identifier && tokens[index].text == loop.row {
                if index > 0, tokens[index - 1].text == "." { continue }
                guard index + 2 < range.upperBound, tokens[index + 1].text == ".", tokens[index + 2].kind == .identifier else {
                    isOpaque = true
                    continue
                }
                let alias = tokens[index + 2].text
                if alias == "id" { continue }
                guard index + 4 < range.upperBound, tokens[index + 3].text == ".", tokens[index + 4].kind == .identifier else {
                    // `row.alias == null` / `!= null` asks whether an optional component is present; that reads nothing.
                    let comparison = index + 5 < range.upperBound
                        && ["=", "!"].contains(tokens[index + 3].text) && tokens[index + 4].text == "="
                        && tokens[index + 5].text == "null"
                    if comparison {
                        reads.insert(alias)
                    } else {
                        // `row.alias` alone: the component view is passed around.
                        isOpaque = true
                    }
                    continue
                }
                let after = index + 5
                let next = after < range.upperBound ? tokens[after].text : ""
                let followedByEquals = after + 1 < range.upperBound && tokens[after + 1].text == "="
                let isPlainAssignment = next == "=" && !followedByEquals
                let isCompound = Self.assignmentOperators.contains(next) && followedByEquals
                    && tokens[after].endOffset == tokens[after + 1].startOffset
                if next == "(", tokens[index + 4].text == "set" {
                    // The component view's explicit setter: `row.alias.set("field", value)`.
                    writes.insert(alias)
                    reads.insert(alias)
                } else if next == "(", tokens[index + 4].text == "get" {
                    reads.insert(alias)
                } else if next == "(" {
                    // Any other call on the component view cannot be classified.
                    isOpaque = true
                } else if isPlainAssignment || isCompound {
                    writes.insert(alias)
                    reads.insert(alias)
                } else {
                    reads.insert(alias)
                }
            }
        }
        return AdaScriptQueryUsage(propertyName: property, reads: reads, writes: writes, isOpaque: isOpaque)
    }
}
