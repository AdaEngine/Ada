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
            advance()
        }
        return output
    }

    private mutating func parseClass(annotations: [Annotation], output: inout Output) throws {
        let declarationLine = current?.line ?? 1
        guard let name = consumeIdentifier() else {
            throw error("expected class name")
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
            throw error("@previewable can only annotate an @view class")
        }

        if let toolAnnotation = toolAnnotations.first {
            output.tools.append(try parseTool(name: name, annotation: toolAnnotation, line: declarationLine))
            try skipDeclarationBody()
        } else if annotations.contains(where: { $0.name == "system" }) {
            let system = try parseSystemBody(systemName: name)
            output.resourceBindings += system.resourceBindings
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
        guard let name = consumeIdentifier() else {
            throw error("expected struct name")
        }
        if annotations.contains(where: { $0.name == "view" || $0.name == "previewable" || $0.name == "tool" }) {
            throw error("@view, @previewable, and @tool can only annotate a class")
        }
        guard let schemaAnnotation = annotations.first(where: { $0.name == "component" || $0.name == "resource" }) else {
            try skipDeclarationBody()
            return
        }
        output.schemas.append(try parseSchema(name: name, annotation: schemaAnnotation))
    }
}

extension Parser {
    private mutating func parseView(
        name: String,
        annotation: Annotation,
        previewAnnotation: Annotation?,
        line: Int
    ) throws -> AdaScriptViewSchema {
        let environment = try parseViewBody(name: name)
        let id: String
        let isIDExplicit: Bool
        if case let .string(explicitID) = annotation.arguments["id"] {
            id = explicitID
            isIDExplicit = true
        } else {
            id = name
            isIDExplicit = false
        }

        let title: String
        let isTitleExplicit: Bool
        if let previewTitle = try previewAnnotation?.previewTitle(viewName: name, path: path) {
            title = previewTitle
            isTitleExplicit = true
        } else if case let .string(explicitTitle) = annotation.arguments["title"] {
            title = explicitTitle
            isTitleExplicit = true
        } else {
            title = humanizedAdaScriptViewTitle(name)
            isTitleExplicit = false
        }

        return AdaScriptViewSchema(
            className: name,
            environment: environment,
            id: id,
            isIDExplicit: isIDExplicit,
            isPreviewable: previewAnnotation != nil,
            isTitleExplicit: isTitleExplicit,
            line: line,
            sourcePath: path,
            title: title
        )
    }

    private mutating func parseViewBody(name: String) throws -> [AdaScriptViewEnvironmentBinding] {
        guard match("{") else {
            throw error("expected '{' after view \(name)")
        }
        var bindings: [AdaScriptViewEnvironmentBinding] = []
        var depth = 1
        while !isAtEnd, depth > 0 {
            if depth == 1 {
                let annotations = try parseAnnotations()
                if let binding = try parseViewEnvironmentBinding(annotations, viewName: name) {
                    bindings.append(binding)
                    continue
                }
                if annotations.contains(where: { $0.name == "binding" }) {
                    throw error("@binding in \(name) requires nested script-view parameters, which are not implemented yet")
                }
            }
            advanceSystemBody(depth: &depth)
        }
        guard depth == 0 else {
            throw error("unterminated view declaration '\(name)'")
        }
        return bindings
    }

    private mutating func parseViewEnvironmentBinding(
        _ annotations: [Annotation],
        viewName: String
    ) throws -> AdaScriptViewEnvironmentBinding? {
        guard let environment = annotations.first(where: { $0.name == "environment" }) else {
            return nil
        }
        guard case let .identifier(key)? = environment.positionalArguments.first else {
            throw error("@environment in \(viewName) requires a symbolic key")
        }
        guard match("var"), let propertyName = consumeIdentifier() else {
            throw error("@environment in \(viewName) must annotate a stored var")
        }
        if match(":"), consumeIdentifier() == nil {
            throw error("expected environment value type for \(propertyName)")
        }
        guard match(";") else {
            throw error("expected ';' after environment property '\(propertyName)'")
        }
        return AdaScriptViewEnvironmentBinding(key: key, propertyName: propertyName)
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
    ) throws -> (resourceBindings: [AdaScriptResourceBinding], capabilities: AdaScriptSystemCapabilities) {
        guard match("{") else {
            throw error("expected '{' after system \(systemName)")
        }
        var bindings: [AdaScriptResourceBinding] = []
        var depth = 1
        var usesDeferredCommands = false
        while !isAtEnd, depth > 0 {
            usesDeferredCommands =
                usesDeferredCommands
                || checkSequence(["context", ".", "world", ".", "commands"])
                || checkSequence(["context", ".", "world", ".", "spawn"])
            if depth == 1, let binding = try parseResourceBinding(systemName: systemName) {
                bindings.append(binding)
                continue
            }
            advanceSystemBody(depth: &depth)
        }
        guard depth == 0 else {
            throw error("unterminated system declaration '\(systemName)'")
        }
        return (
            bindings,
            AdaScriptSystemCapabilities(
                systemName: systemName,
                usesDeferredCommands: usesDeferredCommands
            )
        )
    }

    private mutating func parseResourceBinding(systemName: String) throws -> AdaScriptResourceBinding? {
        let annotations = try parseAnnotations()
        guard let resourceAnnotation = annotations.first(where: { $0.name == "res" }) else {
            return nil
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
        return AdaScriptResourceBinding(
            isOptional: isOptional,
            propertyName: propertyName,
            resourceName: resourceName,
            systemName: systemName
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
        let fields = try parseFields(declarationName: name)
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
            sourcePath: path
        )
    }

    private mutating func parseFields(declarationName: String) throws -> [AdaScriptSchemaField] {
        var fields: [AdaScriptSchemaField] = []
        var fieldNames = Set<String>()
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
            guard annotations.contains(where: { $0.name == "export" }) else {
                continue
            }
            guard fieldNames.insert(fieldName).inserted else {
                throw error("duplicate field '\(fieldName)' in \(declarationName)")
            }
            fields.append(AdaScriptSchemaField(defaultValue: defaultValue, name: fieldName))
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
        if annotation.name == "component" {
            return .component
        }
        if case let .bool(value) = annotation.arguments["autoInsert"] {
            return .resource(autoInsert: value)
        }
        return .resource(autoInsert: false)
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
