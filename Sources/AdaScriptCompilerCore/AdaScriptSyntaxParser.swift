struct AdaScriptParsedBinding: Sendable {
    var initializerRange: Range<Int>?
    var syntax: AdaScriptBindingSyntax
}

struct AdaScriptParsedFunction: Sendable {
    var bodyRange: Range<Int>?
    var syntax: AdaScriptFunctionSyntax
}

struct AdaScriptParsedType: Sendable {
    var bindings: [AdaScriptParsedBinding]
    var functions: [AdaScriptParsedFunction]
    var syntax: AdaScriptTypeSyntax
}

struct AdaScriptParsedDocument: Sendable {
    var bindings: [AdaScriptParsedBinding]
    var functions: [AdaScriptParsedFunction]
    var syntax: AdaScriptSyntaxTree
    var tokens: [AdaScriptAnalysisToken]
    var types: [AdaScriptParsedType]
}

struct AdaScriptSyntaxParser {
    private static let declarationModifiers: Set<String> = ["async", "extern", "private", "public", "static"]

    private let path: String
    private let tokens: [AdaScriptAnalysisToken]

    init(source: String, path: String) {
        var lexer = AdaScriptAnalysisLexer(source: source)
        self.tokens = lexer.lex().filter { $0.kind != .comment }
        self.path = path
    }

    func parse() -> AdaScriptParsedDocument {
        let parsed = parseDeclarations(in: tokens.indices)
        let syntax = AdaScriptSyntaxTree(
            bindings: parsed.bindings.map(\.syntax),
            functions: parsed.functions.map(\.syntax),
            isStrict: hasFileStrictAnnotation,
            path: path,
            types: parsed.types.map(\.syntax)
        )
        return AdaScriptParsedDocument(
            bindings: parsed.bindings,
            functions: parsed.functions,
            syntax: syntax,
            tokens: tokens,
            types: parsed.types
        )
    }

    private var hasFileStrictAnnotation: Bool {
        var braceDepth = 0
        for index in tokens.indices {
            if tokens[index].text == "{" {
                braceDepth += 1
            } else if tokens[index].text == "}" {
                braceDepth = max(0, braceDepth - 1)
            } else if braceDepth == 0, tokens[index].text == "@", index + 1 < tokens.count,
                tokens[index + 1].text == "strict" {
                return true
            }
        }
        return false
    }

    private func parseDeclarations(in range: Range<Int>) -> ParsedDeclarations {
        var result = ParsedDeclarations()
        var index = range.lowerBound
        while index < range.upperBound {
            let prefix = declarationPrefix(at: index, upperBound: range.upperBound)
            let declarationIndex = prefix.nextIndex
            guard declarationIndex < range.upperBound else {
                break
            }

            switch tokens[declarationIndex].text {
            case "class", "enum", "struct":
                guard let parsed = parseType(
                    at: declarationIndex,
                    annotations: prefix.annotations,
                    upperBound: range.upperBound
                ) else {
                    index += 1
                    continue
                }
                result.types.append(parsed.value)
                index = parsed.nextIndex
            case "func":
                guard let parsed = parseFunction(
                    at: declarationIndex,
                    annotations: prefix.annotations,
                    isAsync: prefix.isAsync,
                    upperBound: range.upperBound
                ) else {
                    index += 1
                    continue
                }
                result.functions.append(parsed.value)
                index = parsed.nextIndex
            case "const", "var":
                guard let parsed = parseBinding(
                    at: declarationIndex,
                    annotations: prefix.annotations,
                    upperBound: range.upperBound
                ) else {
                    index += 1
                    continue
                }
                result.bindings.append(parsed.value)
                index = parsed.nextIndex
            default:
                index += 1
            }
        }
        return result
    }

    private func declarationPrefix(at index: Int, upperBound: Int) -> DeclarationPrefix {
        var annotations: [AdaScriptAnnotationSyntax] = []
        var cursor = index
        var isAsync = false
        while cursor < upperBound {
            if tokens[cursor].text == "@", let parsed = parseAnnotation(at: cursor, upperBound: upperBound) {
                annotations.append(parsed.value)
                cursor = parsed.nextIndex
                continue
            }
            if Self.declarationModifiers.contains(tokens[cursor].text) {
                isAsync = isAsync || tokens[cursor].text == "async"
                cursor += 1
                continue
            }
            break
        }
        return DeclarationPrefix(annotations: annotations, isAsync: isAsync, nextIndex: cursor)
    }

    private func parseAnnotation(
        at index: Int,
        upperBound: Int
    ) -> (value: AdaScriptAnnotationSyntax, nextIndex: Int)? {
        guard index + 1 < upperBound, tokens[index + 1].kind == .identifier else {
            return nil
        }
        let nameToken = tokens[index + 1]
        var arguments: [String] = []
        var endIndex = index + 1
        if index + 2 < upperBound, tokens[index + 2].text == "(",
            let closeIndex = matchingIndex(openingAt: index + 2, opening: "(", closing: ")", upperBound: upperBound) {
            arguments = annotationArguments(in: (index + 3)..<closeIndex)
            endIndex = closeIndex
        }
        return (
            AdaScriptAnnotationSyntax(
                arguments: arguments,
                name: nameToken.text,
                range: AdaScriptSourceRange(start: tokens[index].range.start, end: tokens[endIndex].range.end)
            ),
            endIndex + 1
        )
    }

    private func annotationArguments(in range: Range<Int>) -> [String] {
        splitTopLevel(range, separator: ",").flatMap { argumentRange -> [String] in
            guard firstTopLevelToken(":", in: argumentRange) == nil else {
                return []
            }
            return argumentRange.compactMap { index in
                tokens[index].kind == .identifier ? tokens[index].text : nil
            }
        }
    }

    private func parseType(
        at index: Int,
        annotations: [AdaScriptAnnotationSyntax],
        upperBound: Int
    ) -> (value: AdaScriptParsedType, nextIndex: Int)? {
        guard
            index + 1 < upperBound,
            tokens[index + 1].kind == .identifier,
            let openIndex = nextToken("{", after: index + 1, upperBound: upperBound),
            let closeIndex = matchingIndex(openingAt: openIndex, opening: "{", closing: "}", upperBound: upperBound)
        else {
            return nil
        }
        let name = tokens[index + 1].text
        let members = parseDeclarations(in: (openIndex + 1)..<closeIndex)
        let kind: AdaScriptTypeSyntax.Kind =
            switch tokens[index].text {
            case "class": .class
            case "enum": .enum
            default: .struct
            }
        let syntax = AdaScriptTypeSyntax(
            annotations: annotations,
            bindings: members.bindings.map(\.syntax),
            functions: members.functions.map(\.syntax),
            kind: kind,
            name: name,
            range: AdaScriptSourceRange(start: tokens[index].range.start, end: tokens[closeIndex].range.end)
        )
        return (
            AdaScriptParsedType(
                bindings: members.bindings,
                functions: members.functions,
                syntax: syntax
            ),
            closeIndex + 1
        )
    }

    private func parseFunction(
        at index: Int,
        annotations: [AdaScriptAnnotationSyntax],
        isAsync: Bool,
        upperBound: Int
    ) -> (value: AdaScriptParsedFunction, nextIndex: Int)? {
        guard
            index + 2 < upperBound,
            tokens[index + 1].kind == .identifier,
            let openParenthesis = nextToken("(", after: index + 1, upperBound: upperBound),
            let closeParenthesis = matchingIndex(
                openingAt: openParenthesis,
                opening: "(",
                closing: ")",
                upperBound: upperBound
            )
        else {
            return nil
        }
        let nameToken = tokens[index + 1]
        let parameters = parseParameters(in: (openParenthesis + 1)..<closeParenthesis)
        var cursor = closeParenthesis + 1
        var returnType: AdaScriptType?
        if cursor + 1 < upperBound, tokens[cursor].text == "-", tokens[cursor + 1].text == ">" {
            cursor += 2
            if let parsedType = parseTypeReference(at: cursor, upperBound: upperBound) {
                returnType = parsedType.value
                cursor = parsedType.nextIndex
            }
        } else if cursor < upperBound, tokens[cursor].text == ":" {
            cursor += 1
            if let parsedType = parseTypeReference(at: cursor, upperBound: upperBound) {
                returnType = parsedType.value
                cursor = parsedType.nextIndex
            }
        }

        var bodyRange: Range<Int>?
        var endIndex = closeParenthesis
        if let openBrace = nextToken("{", atOrAfter: cursor, upperBound: upperBound),
            let closeBrace = matchingIndex(openingAt: openBrace, opening: "{", closing: "}", upperBound: upperBound) {
            bodyRange = (openBrace + 1)..<closeBrace
            endIndex = closeBrace
        } else if let semicolon = nextToken(";", atOrAfter: cursor, upperBound: upperBound) {
            endIndex = semicolon
        }
        let syntax = AdaScriptFunctionSyntax(
            annotations: annotations,
            isAsync: isAsync,
            name: nameToken.text,
            parameters: parameters,
            range: AdaScriptSourceRange(start: tokens[index].range.start, end: tokens[endIndex].range.end),
            returnType: returnType
        )
        return (AdaScriptParsedFunction(bodyRange: bodyRange, syntax: syntax), endIndex + 1)
    }

    private func parseParameters(in range: Range<Int>) -> [AdaScriptParameterSyntax] {
        splitTopLevel(range, separator: ",").compactMap { parameterRange in
            var cursor = parameterRange.lowerBound
            while cursor < parameterRange.upperBound, tokens[cursor].text == "@" {
                guard let annotation = parseAnnotation(at: cursor, upperBound: parameterRange.upperBound) else {
                    break
                }
                cursor = annotation.nextIndex
            }
            guard cursor < parameterRange.upperBound, tokens[cursor].kind == .identifier else {
                return nil
            }
            let nameToken = tokens[cursor]
            cursor += 1
            var declaredType: AdaScriptType?
            if cursor < parameterRange.upperBound, tokens[cursor].text == ":" {
                cursor += 1
                if let parsedType = parseTypeReference(at: cursor, upperBound: parameterRange.upperBound) {
                    declaredType = parsedType.value
                    cursor = parsedType.nextIndex
                }
            }
            let hasDefaultValue = (cursor..<parameterRange.upperBound).contains { tokens[$0].text == "=" }
            return AdaScriptParameterSyntax(
                declaredType: declaredType,
                hasDefaultValue: hasDefaultValue,
                name: nameToken.text,
                range: nameToken.range
            )
        }
    }

    private func parseBinding(
        at index: Int,
        annotations: [AdaScriptAnnotationSyntax],
        upperBound: Int
    ) -> (value: AdaScriptParsedBinding, nextIndex: Int)? {
        guard index + 1 < upperBound, tokens[index + 1].kind == .identifier else {
            return nil
        }
        let nameToken = tokens[index + 1]
        var cursor = index + 2
        var declaredType: AdaScriptType?
        if cursor < upperBound, tokens[cursor].text == ":" {
            cursor += 1
            if let parsedType = parseTypeReference(at: cursor, upperBound: upperBound) {
                declaredType = parsedType.value
                cursor = parsedType.nextIndex
            }
        }

        let endIndex = bindingEndIndex(from: cursor, upperBound: upperBound)
        var initializerRange: Range<Int>?
        if cursor < endIndex, tokens[cursor].text == "=" {
            initializerRange = (cursor + 1)..<endIndex
        }
        let syntax = AdaScriptBindingSyntax(
            annotations: annotations,
            declaredType: declaredType,
            isConstant: tokens[index].text == "const",
            name: nameToken.text,
            range: AdaScriptSourceRange(start: tokens[index].range.start, end: tokens[max(index + 1, endIndex - 1)].range.end)
        )
        return (AdaScriptParsedBinding(initializerRange: initializerRange, syntax: syntax), max(index + 2, endIndex + 1))
    }

    private func parseTypeReference(at index: Int, upperBound: Int) -> (value: AdaScriptType, nextIndex: Int)? {
        guard index < upperBound else {
            return nil
        }
        if tokens[index].text == "[" {
            guard let close = matchingIndex(openingAt: index, opening: "[", closing: "]", upperBound: upperBound) else {
                return nil
            }
            if let colon = firstTopLevelToken(":", in: (index + 1)..<close),
                let key = parseTypeReference(at: index + 1, upperBound: colon),
                let value = parseTypeReference(at: colon + 1, upperBound: close) {
                return (.map(key: key.value, value: value.value), close + 1)
            }
            let element = parseTypeReference(at: index + 1, upperBound: close)?.value ?? .unknown
            return (.list(element), close + 1)
        }
        guard tokens[index].kind == .identifier else {
            return nil
        }
        let name = tokens[index].text
        if index + 1 < upperBound, tokens[index + 1].text == "<",
            let close = matchingIndex(openingAt: index + 1, opening: "<", closing: ">", upperBound: upperBound) {
            let arguments = splitTopLevel((index + 2)..<close, separator: ",").compactMap { range in
                parseTypeReference(at: range.lowerBound, upperBound: range.upperBound)?.value
            }
            if name == "List", let element = arguments.first {
                return (.list(element), close + 1)
            }
            if name == "Map", arguments.count == 2 {
                return (.map(key: arguments[0], value: arguments[1]), close + 1)
            }
        }
        return (AdaScriptType(spelling: name), index + 1)
    }

    private func bindingEndIndex(from index: Int, upperBound: Int) -> Int {
        guard index < upperBound else {
            return upperBound
        }
        if tokens[index].text == "{",
            let close = matchingIndex(openingAt: index, opening: "{", closing: "}", upperBound: upperBound) {
            return close + 1
        }
        var depths = DelimiterDepth()
        var cursor = index
        while cursor < upperBound {
            let token = tokens[cursor]
            depths.consume(token.text)
            if depths.isTopLevel, token.text == ";" {
                return cursor
            }
            if depths.isTopLevel, token.text == "}" {
                return cursor
            }
            if depths.isTopLevel, cursor > index, token.range.start.line > tokens[cursor - 1].range.start.line,
                Self.startsDeclaration.contains(token.text) {
                return cursor
            }
            cursor += 1
        }
        return upperBound
    }

    private func splitTopLevel(_ range: Range<Int>, separator: String) -> [Range<Int>] {
        guard !range.isEmpty else {
            return []
        }
        var result: [Range<Int>] = []
        var start = range.lowerBound
        var depths = DelimiterDepth()
        for index in range {
            let token = tokens[index]
            if depths.isTopLevel, token.text == separator {
                if start < index {
                    result.append(start..<index)
                }
                start = index + 1
            } else {
                depths.consume(token.text)
            }
        }
        if start < range.upperBound {
            result.append(start..<range.upperBound)
        }
        return result
    }

    private func firstTopLevelToken(_ text: String, in range: Range<Int>) -> Int? {
        var depths = DelimiterDepth()
        for index in range {
            if depths.isTopLevel, tokens[index].text == text {
                return index
            }
            depths.consume(tokens[index].text)
        }
        return nil
    }

    private func nextToken(_ text: String, after index: Int, upperBound: Int) -> Int? {
        nextToken(text, atOrAfter: index + 1, upperBound: upperBound)
    }

    private func nextToken(_ text: String, atOrAfter index: Int, upperBound: Int) -> Int? {
        var cursor = index
        while cursor < upperBound {
            if tokens[cursor].text == text {
                return cursor
            }
            if tokens[cursor].text == ";" || tokens[cursor].text == "}" {
                return nil
            }
            cursor += 1
        }
        return nil
    }

    private func matchingIndex(
        openingAt index: Int,
        opening: String,
        closing: String,
        upperBound: Int
    ) -> Int? {
        var depth = 0
        for cursor in index..<upperBound {
            if tokens[cursor].text == opening {
                depth += 1
            } else if tokens[cursor].text == closing {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
            }
        }
        return nil
    }

    private static let startsDeclaration: Set<String> = [
        "async", "class", "const", "enum", "extern", "func", "private", "public", "static", "struct", "var",
    ]
}

private struct ParsedDeclarations {
    var bindings: [AdaScriptParsedBinding] = []
    var functions: [AdaScriptParsedFunction] = []
    var types: [AdaScriptParsedType] = []
}

private struct DeclarationPrefix {
    var annotations: [AdaScriptAnnotationSyntax]
    var isAsync: Bool
    var nextIndex: Int
}

private struct DelimiterDepth {
    private var braces = 0
    private var brackets = 0
    private var parentheses = 0

    var isTopLevel: Bool {
        braces == 0 && brackets == 0 && parentheses == 0
    }

    mutating func consume(_ token: String) {
        switch token {
        case "(": parentheses += 1
        case ")": parentheses = max(0, parentheses - 1)
        case "[": brackets += 1
        case "]": brackets = max(0, brackets - 1)
        case "{": braces += 1
        case "}": braces = max(0, braces - 1)
        default: break
        }
    }
}
