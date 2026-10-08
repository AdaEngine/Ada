public enum AdaScriptViewBuilderLowerer {
    public static func lower(source: String, path: String) throws -> String {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        if let viewIndex = tokens.indices.dropLast().first(where: { tokens[$0].text == "@" && tokens[$0 + 1].text == "view" }) {
            throw AdaScriptViewBuilderError(
                path: path,
                line: tokens[viewIndex].line,
                message: "AdaUI views in AdaScript are temporarily unavailable."
            )
        }
        let characters = Array(source)
        let replacements = try replacements(tokens: tokens, characters: characters, path: path)

        var result = characters
        for replacement in replacements.sorted(by: { $0.startOffset > $1.startOffset }) {
            result.replaceSubrange(replacement.startOffset..<replacement.endOffset, with: Array(replacement.source))
        }
        return String(result)
    }
}

public struct AdaScriptViewBuilderError: Error, Equatable, Sendable, CustomStringConvertible {
    public let path: String
    public let line: Int
    public let message: String

    public var description: String {
        "Invalid Ada Script view builder in '\(path)' at line \(line): \(message)"
    }

    public init(path: String, line: Int, message: String) {
        self.path = path
        self.line = line
        self.message = message
    }
}

extension AdaScriptViewBuilderLowerer {
    private static func replacements(
        tokens: [Token],
        characters: [Character],
        path: String
    ) throws -> [Replacement] {
        var replacements: [Replacement] = []
        var index = 0

        while index + 1 < tokens.count {
            guard tokens[index].text == "@", tokens[index + 1].text == "view" else {
                index += 1
                continue
            }

            let declarationIndex = try declarationIndex(afterViewAt: index, tokens: tokens, path: path)
            guard tokens.indices.contains(declarationIndex), ["class", "struct"].contains(tokens[declarationIndex].text) else {
                index += 2
                continue
            }
            guard
                let classOpen = tokens[declarationIndex...].firstIndex(where: { $0.text == "{" }),
                let classClose = matchingIndex(openingIndex: classOpen, opening: "{", closing: "}", tokens: tokens)
            else {
                throw AdaScriptViewBuilderError(path: path, line: tokens[declarationIndex].line, message: "unterminated @view declaration")
            }

            if let bodyRange = try bodyRange(in: classOpen..<classClose, tokens: tokens, path: path),
                let loweredBody = try lowerBody(
                    range: bodyRange,
                    tokens: tokens,
                    characters: characters,
                    path: path
                ) {
                replacements.append(loweredBody.replacement)
                if !loweredBody.generatedMembers.isEmpty {
                    replacements.append(
                        Replacement(
                            endOffset: tokens[classClose].startOffset,
                            source: "    \(loweredBody.generatedMembers.joined(separator: "\n    "))\n",
                            startOffset: tokens[classClose].startOffset
                        )
                    )
                }
            }
            index = classClose + 1
        }
        return replacements
    }

    private static func declarationIndex(afterViewAt viewIndex: Int, tokens: [Token], path: String) throws -> Int {
        var declarationIndex = viewIndex + 2
        if tokens.indices.contains(declarationIndex), tokens[declarationIndex].text == "(" {
            declarationIndex = try indexAfterGroup(
                openingIndex: declarationIndex,
                opening: "(",
                closing: ")",
                tokens: tokens,
                path: path
            )
        }
        while tokens.indices.contains(declarationIndex), tokens[declarationIndex].text == "@" {
            guard tokens.indices.contains(declarationIndex + 1), tokens[declarationIndex + 1].kind == .identifier else {
                throw AdaScriptViewBuilderError(
                    path: path,
                    line: tokens[declarationIndex].line,
                    message: "expected annotation name after @view"
                )
            }
            declarationIndex += 2
            if tokens.indices.contains(declarationIndex), tokens[declarationIndex].text == "(" {
                declarationIndex = try indexAfterGroup(
                    openingIndex: declarationIndex,
                    opening: "(",
                    closing: ")",
                    tokens: tokens,
                    path: path
                )
            }
        }
        return declarationIndex
    }

    private struct Replacement {
        let endOffset: Int
        let source: String
        let startOffset: Int
    }

    private struct LoweredViewBody {
        let generatedMembers: [String]
        let replacement: Replacement
    }

    private static func bodyRange(
        in classRange: Range<Int>,
        tokens: [Token],
        path: String
    ) throws -> Range<Int>? {
        var depth = 1
        var index = classRange.lowerBound + 1
        while index < classRange.upperBound {
            if tokens[index].text == "{" {
                depth += 1
            } else if tokens[index].text == "}" {
                depth -= 1
            } else if depth == 1,
                tokens[index].text == "func",
                tokens.indices.contains(index + 1),
                tokens[index + 1].text == "body" {
                guard
                    let parametersOpen = tokens[(index + 2)..<classRange.upperBound].firstIndex(where: { $0.text == "(" }),
                    let parametersClose = matchingIndex(
                        openingIndex: parametersOpen,
                        opening: "(",
                        closing: ")",
                        tokens: tokens
                    ),
                    let bodyOpen = tokens[(parametersClose + 1)..<classRange.upperBound].firstIndex(where: { $0.text == "{" }),
                    let bodyClose = matchingIndex(openingIndex: bodyOpen, opening: "{", closing: "}", tokens: tokens)
                else {
                    throw AdaScriptViewBuilderError(path: path, line: tokens[index].line, message: "unterminated body()")
                }
                return bodyOpen..<bodyClose
            }
            index += 1
        }
        return nil
    }

    private static func lowerBody(
        range: Range<Int>,
        tokens: [Token],
        characters: [Character],
        path: String
    ) throws -> LoweredViewBody? {
        let firstTokenIndex = range.lowerBound + 1
        guard firstTokenIndex < range.upperBound else {
            return nil
        }
        if tokens[firstTokenIndex].text == "return" || tokens[firstTokenIndex].text == "var" {
            return nil
        }

        var parser = ViewExpressionParser(
            characters: characters,
            endIndex: range.upperBound,
            index: firstTokenIndex,
            path: path,
            tokens: tokens
        )
        let expression = try parser.parseViewExpression()
        parser.consumeSemicolons()
        guard parser.index == range.upperBound else {
            throw parser.error("body() must contain one declarative view expression")
        }
        return LoweredViewBody(
            generatedMembers: parser.generatedMembers,
            replacement: Replacement(
                endOffset: tokens[range.upperBound].startOffset,
                source: "\n        return \(expression);\n    ",
                startOffset: tokens[range.lowerBound].endOffset
            )
        )
    }

    private static func indexAfterGroup(
        openingIndex: Int,
        opening: String,
        closing: String,
        tokens: [Token],
        path: String
    ) throws -> Int {
        guard
            let closingIndex = matchingIndex(
                openingIndex: openingIndex,
                opening: opening,
                closing: closing,
                tokens: tokens
            )
        else {
            throw AdaScriptViewBuilderError(path: path, line: tokens[openingIndex].line, message: "unterminated '\(opening)'")
        }
        return closingIndex + 1
    }

    static func matchingIndex(
        openingIndex: Int,
        opening: String,
        closing: String,
        tokens: [Token]
    ) -> Int? {
        var depth = 0
        for index in openingIndex..<tokens.count {
            if tokens[index].text == opening {
                depth += 1
            } else if tokens[index].text == closing {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }
        return nil
    }
}

private struct ViewExpressionParser {
    private struct Argument {
        let label: String?
        let source: String
    }

    let characters: [Character]
    let endIndex: Int
    var generatedMembers: [String] = []
    var index: Int
    let path: String
    let tokens: [Token]

    mutating func parseViewExpression() throws -> String {
        guard index < endIndex, tokens[index].kind == .identifier else {
            throw error("expected an AdaUI view expression")
        }
        let name = tokens[index].text
        let line = tokens[index].line
        index += 1
        let arguments = try parseArguments()

        let expression = try baseExpression(name: name, arguments: arguments, line: line)
        return try appendingModifiers(to: expression)
    }

    mutating func consumeSemicolons() {
        while index < endIndex, tokens[index].text == ";" {
            index += 1
        }
    }

    func error(_ message: String) -> AdaScriptViewBuilderError {
        let line = tokens.indices.contains(index) ? tokens[index].line : tokens[max(endIndex - 1, 0)].line
        return AdaScriptViewBuilderError(path: path, line: line, message: message)
    }

    private mutating func baseExpression(name: String, arguments: [Argument], line: Int) throws -> String {
        switch name {
        case "Button":
            return try buttonExpression(arguments: arguments, line: line)
        case "Divider":
            try requireNoArguments(arguments, name: name, line: line)
            return "adaUIBuilder.divider()"
        case "EmptyView":
            try requireNoArguments(arguments, name: name, line: line)
            return "adaUIBuilder.empty()"
        case "HStack",
            "VStack",
            "ZStack":
            return try stackExpression(name: name, arguments: arguments, line: line)
        case "Spacer":
            return try spacerExpression(arguments: arguments, line: line)
        case "Text":
            return try textExpression(arguments: arguments, line: line)
        case "NativeView":
            guard let identifier = arguments.first, identifier.label == nil else {
                throw AdaScriptViewBuilderError(path: path, line: line, message: "NativeView requires an exported descriptor identifier")
            }
            var expression = "adaUIBuilder.nativeView(\(identifier.source))"
            for argument in arguments.dropFirst() {
                guard let label = argument.label else {
                    throw error("NativeView arguments must be named")
                }
                expression += ".argument(\"\(label)\", \(argument.source))"
            }
            if index < endIndex, tokens[index].text == "{" {
                for child in try parseChildren(name: name, line: line) { expression += ".child(\(child))" }
            }
            return expression
        default:
            throw AdaScriptViewBuilderError(path: path, line: line, message: "unsupported view constructor '\(name)'")
        }
    }

    private mutating func appendingModifiers(to base: String) throws -> String {
        var expression = base
        while index < endIndex, tokens[index].text == "." {
            let modifierStart = tokens[index].startOffset
            index += 1
            guard index < endIndex, tokens[index].kind == .identifier else {
                throw error("expected modifier name after '.'")
            }
            let modifierName = tokens[index].text
            let modifierLine = tokens[index].line
            index += 1
            guard index < endIndex, tokens[index].text == "(" else {
                throw error("view modifiers must be called with parentheses")
            }
            guard
                let modifierEndIndex = AdaScriptViewBuilderLowerer.matchingIndex(
                    openingIndex: index,
                    opening: "(",
                    closing: ")",
                    tokens: tokens
                )
            else {
                throw error("unterminated view modifier")
            }
            let arguments = try parseArguments()
            try validateModifier(modifierName, arguments: arguments, line: modifierLine)
            let modifierEnd = tokens[modifierEndIndex].endOffset
            expression += String(characters[modifierStart..<modifierEnd])
        }
        return expression
    }

    private func validateModifier(_ name: String, arguments: [Argument], line: Int) throws {
        let expectedCount: Int?
        switch name {
        case "accessibilityIdentifier",
            "background",
            "fontSize",
            "foregroundColor",
            "opacity",
            "padding":
            expectedCount = 1
        case "frame":
            expectedCount = 2
        default:
            expectedCount = nil
        }
        guard let expectedCount, arguments.count != expectedCount else {
            return
        }
        let noun = expectedCount == 1 ? "argument" : "arguments"
        throw AdaScriptViewBuilderError(
            path: path,
            line: line,
            message: "\(name) requires \(expectedCount) \(noun)"
        )
    }

    private mutating func buttonExpression(arguments: [Argument], line: Int) throws -> String {
        guard arguments.count == 1, arguments[0].label == nil else {
            throw AdaScriptViewBuilderError(path: path, line: line, message: "Button requires one unlabeled title")
        }
        let actionName = try parseActionBlock(line: line)
        return "adaUIBuilder.button(\(arguments[0].source), \"\(actionName)\")"
    }

    private mutating func stackExpression(name: String, arguments: [Argument], line: Int) throws -> String {
        let children = try parseChildren(name: name, line: line)
        let constructor = name == "HStack" ? "hStack" : (name == "VStack" ? "vStack" : "zStack")
        var expression = "adaUIBuilder.\(constructor)()"
        if let spacing = arguments.first(where: { $0.label == "spacing" })?.source {
            guard name != "ZStack" else {
                throw AdaScriptViewBuilderError(path: path, line: line, message: "ZStack does not accept spacing")
            }
            expression += ".spacing(\(spacing))"
        }
        guard arguments.allSatisfy({ $0.label == "spacing" }) else {
            throw AdaScriptViewBuilderError(path: path, line: line, message: "unsupported \(name) argument")
        }
        for child in children {
            expression += ".child(\(child))"
        }
        return expression
    }

    private func spacerExpression(arguments: [Argument], line: Int) throws -> String {
        guard arguments.count <= 1, arguments.first?.label == nil else {
            throw AdaScriptViewBuilderError(path: path, line: line, message: "Spacer accepts at most one minimum length")
        }
        guard let minLength = arguments.first?.source else {
            return "adaUIBuilder.spacer()"
        }
        return "adaUIBuilder.spacer().spacerMinLength(\(minLength))"
    }

    private func textExpression(arguments: [Argument], line: Int) throws -> String {
        guard arguments.count == 1, arguments[0].label == nil else {
            throw AdaScriptViewBuilderError(path: path, line: line, message: "Text requires one unlabeled value")
        }
        return "adaUIBuilder.text(\(arguments[0].source))"
    }

    private mutating func parseArguments() throws -> [Argument] {
        guard index < endIndex, tokens[index].text == "(" else {
            return []
        }
        let openingIndex = index
        guard
            let closingIndex = AdaScriptViewBuilderLowerer.matchingIndex(
                openingIndex: openingIndex,
                opening: "(",
                closing: ")",
                tokens: tokens
            ), closingIndex <= endIndex
        else {
            throw error("unterminated argument list")
        }
        index += 1
        var arguments: [Argument] = []
        var argumentStart = index
        var nestedDepth = 0
        while index < closingIndex {
            let token = tokens[index].text
            if ["(", "[", "{"].contains(token) {
                nestedDepth += 1
            } else if [")", "]", "}"].contains(token) {
                nestedDepth -= 1
            } else if token == ",", nestedDepth == 0 {
                arguments.append(try makeArgument(argumentStart..<index))
                argumentStart = index + 1
            }
            index += 1
        }
        if argumentStart < closingIndex {
            arguments.append(try makeArgument(argumentStart..<closingIndex))
        }
        index = closingIndex + 1
        return arguments
    }

    private mutating func parseChildren(name: String, line: Int) throws -> [String] {
        guard index < endIndex, tokens[index].text == "{" else {
            throw AdaScriptViewBuilderError(path: path, line: line, message: "\(name) requires a view-builder block")
        }
        index += 1
        var children: [String] = []
        while index < endIndex, tokens[index].text != "}" {
            children.append(try parseViewExpression())
            consumeSemicolons()
        }
        guard index < endIndex, tokens[index].text == "}" else {
            throw AdaScriptViewBuilderError(path: path, line: line, message: "unterminated \(name) builder block")
        }
        index += 1
        return children
    }

    private mutating func parseActionBlock(line: Int) throws -> String {
        guard index < endIndex, tokens[index].text == "{" else {
            throw AdaScriptViewBuilderError(path: path, line: line, message: "Button requires an action block")
        }
        let openingIndex = index
        guard
            let closingIndex = AdaScriptViewBuilderLowerer.matchingIndex(
                openingIndex: openingIndex,
                opening: "{",
                closing: "}",
                tokens: tokens
            ), closingIndex < endIndex
        else {
            throw AdaScriptViewBuilderError(path: path, line: line, message: "unterminated Button action")
        }
        let actionName = "__ada_view_action_\(generatedMembers.count)"
        let sourceStart = tokens[openingIndex].endOffset
        let sourceEnd = tokens[closingIndex].startOffset
        generatedMembers.append("func \(actionName)() {\(String(characters[sourceStart..<sourceEnd]))}")
        index = closingIndex + 1
        return actionName
    }

    private func makeArgument(_ range: Range<Int>) throws -> Argument {
        guard !range.isEmpty else {
            throw error("empty argument")
        }
        let label: String?
        let sourceStartIndex: Int
        if range.count >= 3, tokens[range.lowerBound].kind == .identifier, tokens[range.lowerBound + 1].text == ":" {
            label = tokens[range.lowerBound].text
            sourceStartIndex = range.lowerBound + 2
        } else {
            label = nil
            sourceStartIndex = range.lowerBound
        }
        guard sourceStartIndex < range.upperBound else {
            throw error("missing argument value")
        }
        let startOffset = tokens[sourceStartIndex].startOffset
        let endOffset = tokens[range.upperBound - 1].endOffset
        return Argument(label: label, source: String(characters[startOffset..<endOffset]))
    }

    private func requireNoArguments(_ arguments: [Argument], name: String, line: Int) throws {
        guard arguments.isEmpty else {
            throw AdaScriptViewBuilderError(path: path, line: line, message: "\(name) does not accept arguments")
        }
    }
}
