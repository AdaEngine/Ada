import Foundation

public struct AdaScriptAsyncSyntaxError: Error, Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let line: Int
    public let message: String

    public var description: String { "\(path):\(line): \(message)" }
}

public struct AdaScriptAsyncDeclaration: Equatable, Sendable {
    public let name: String
    public let ownerType: String?
    public let line: Int
}

/// Interim adapter for the pinned Gravity 0.9.9 parser, which has no async AST.
/// Borrow rules come from `@nonsendable` type metadata and runtime bridge policy;
/// native async syntax/effects belong in a future versioned Gravity release.
public enum AdaScriptAsyncLowerer {
    private struct Declaration {
        let range: Range<Int>
        let body: Range<Int>
        let name: String
        let parameters: String
        let arguments: [String]
        let receiver: String
        let ownerType: String?
        let line: Int
    }

    private struct Parameter {
        let name: String
        let typeName: String?
    }

    private enum Scope {
        case type(String)
        case other
    }

    public static func globalFunctionNames(source: String, path: String) throws -> Set<String> {
        Set(try declarations(in: source, path: path).compactMap { $0.ownerType == nil ? $0.name : nil })
    }

    public static func declarations(
        in source: String,
        path: String,
        nonSendableTypes: Set<String> = []
    ) throws -> [AdaScriptAsyncDeclaration] {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        let characters = Array(source)
        let markedTypes = try nonSendableTypes.union(AdaScriptNonSendableTypes.declared(in: source, path: path))
        var declarations: [AdaScriptAsyncDeclaration] = []
        for index in tokens.indices where tokens[index].text == "async" {
            let declaration = try parse(
                at: index,
                tokens: tokens,
                characters: characters,
                path: path,
                nonSendableTypes: markedTypes
            )
            declarations.append(
                AdaScriptAsyncDeclaration(name: declaration.name, ownerType: declaration.ownerType, line: declaration.line)
            )
        }
        return declarations
    }

    public static func lower(
        source: String,
        path: String,
        globalAsyncNames: Set<String> = [],
        nonSendableTypes: Set<String> = []
    ) throws -> String {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        let characters = Array(source)
        let markedTypes = try nonSendableTypes.union(AdaScriptNonSendableTypes.declared(in: source, path: path))
        var declarations: [Declaration] = []
        var covered = Set<Int>()

        for index in tokens.indices where tokens[index].text == "async" {
            guard !covered.contains(index) else { continue }
            let declaration = try parse(
                at: index,
                tokens: tokens,
                characters: characters,
                path: path,
                nonSendableTypes: markedTypes
            )
            declarations.append(declaration)
            for tokenIndex in index..<tokens.count where declaration.range.contains(tokens[tokenIndex].startOffset) {
                covered.insert(tokenIndex)
            }
        }
        for index in tokens.indices where tokens[index].text == "await" && !covered.contains(index) {
            throw error(path, tokens[index].line, "await requires an async func")
        }
        try validateGlobalAsyncCalls(declarations: declarations, globalAsyncNames: globalAsyncNames, tokens: tokens, path: path)

        var result = characters
        for declaration in declarations.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let body = try lowerAwaits(
                String(characters[declaration.body]),
                path: path,
                firstLine: declaration.line
            )
            let implementation = "__ada_async_impl_\(declaration.name)_\(declaration.range.lowerBound)"
            let call = "\(declaration.receiver)\(implementation)(\(declaration.arguments.joined(separator: ", ")))"
            let capturedReceiver = declaration.receiver.isEmpty ? "" : "var __ada_receiver = self;\n    "
            let capturedValues = (declaration.receiver.isEmpty ? [] : ["__ada_receiver"]) + declaration.arguments
            let replacement = """
            func \(declaration.name)(\(declaration.parameters)) {
                \(capturedReceiver)var __ada_task = __AdaTask();
                if (!__adaTasks.validateCapture([\(capturedValues.joined(separator: ", "))])) {
                    __ada_task.cancel();
                    return __ada_task;
                }
                __ada_task.fiber = Fiber.create({
                    var __ada_result = \(call);
                    if (!__adaTasks.validateCapture([__ada_result])) {
                        __ada_task.cancel();
                        return;
                    }
                    __ada_task.value = __ada_result;
                    __ada_task.done = true;
                });
                return __ada_task;
            }
            func \(implementation)(\(declaration.parameters)) \(body)
            """
            result.replaceSubrange(declaration.range, with: Array(replacement))
        }
        return String(result)
    }

    private static func parse(
        at index: Int,
        tokens: [Token],
        characters: [Character],
        path: String,
        nonSendableTypes: Set<String>
    ) throws -> Declaration {
        let token = tokens[index]
        guard tokens.indices.contains(index + 3), tokens[index + 1].text == "func",
              tokens[index + 2].kind == .identifier, tokens[index + 3].text == "(",
              let closeParameters = closing(index + 3, tokens: tokens, open: "(", close: ")"),
              tokens.indices.contains(closeParameters + 1), tokens[closeParameters + 1].text == "{",
              let closeBody = closing(closeParameters + 1, tokens: tokens, open: "{", close: "}") else {
            throw error(path, token.line, "expected 'async func name(...) { ... }'")
        }
        let ownerType = try enclosingType(at: index, tokens: tokens, path: path)
        let name = tokens[index + 2].text
        if let ownerType, nonSendableTypes.contains(ownerType) {
            throw error(path, token.line, "async method captures @nonsendable type '\(ownerType)'")
        }
        let parameters = try parameterDeclarations(Array(tokens[(index + 4)..<closeParameters]), path: path, line: token.line)
        if let forbidden = parameters.first(where: { $0.typeName.map(nonSendableTypes.contains) == true }) {
            throw error(path, token.line, "async parameter '\(forbidden.name)' has @nonsendable type '\(forbidden.typeName ?? "")'")
        }
        return Declaration(
            range: token.startOffset..<tokens[closeBody].endOffset,
            body: tokens[closeParameters + 1].startOffset..<tokens[closeBody].endOffset,
            name: name,
            parameters: String(characters[tokens[index + 3].endOffset..<tokens[closeParameters].startOffset]),
            arguments: parameters.map(\.name),
            receiver: ownerType == nil ? "" : "__ada_receiver.",
            ownerType: ownerType,
            line: token.line
        )
    }

    private static func validateGlobalAsyncCalls(
        declarations: [Declaration],
        globalAsyncNames: Set<String>,
        tokens: [Token],
        path: String
    ) throws {
        let globalNames = globalAsyncNames.union(declarations.filter { $0.ownerType == nil }.map(\.name))
        guard !globalNames.isEmpty else {
            return
        }
        for index in tokens.indices where globalNames.contains(tokens[index].text) {
            guard tokens.indices.contains(index + 1), tokens[index + 1].text == "(",
                  index > 0, tokens[index - 1].text != "func", tokens[index - 1].text != "." else { continue }
            let awaited = tokens[index - 1].text == "await"
            let started = index >= 4 && tokens[index - 1].text == "(" && tokens[index - 2].text == "start"
                && tokens[index - 3].text == "." && tokens[index - 4].text == "Tasks"
            guard awaited || started else {
                throw error(path, tokens[index].line, "async call '\(tokens[index].text)' requires await or Tasks.start")
            }
        }
    }

    private static func enclosingType(at index: Int, tokens: [Token], path: String) throws -> String? {
        var scopes: [Scope] = []
        var segment = 0
        for cursor in 0..<index {
            switch tokens[cursor].text {
            case "{":
                let declaration = tokens[segment..<cursor]
                let typeIndex = declaration.firstIndex(where: { ["class", "struct", "enum"].contains($0.text) })
                if let typeIndex, tokens.indices.contains(typeIndex + 1), tokens[typeIndex + 1].kind == .identifier {
                    scopes.append(.type(tokens[typeIndex + 1].text))
                } else {
                    scopes.append(.other)
                }
                segment = cursor + 1
            case "}":
                guard !scopes.isEmpty else { throw error(path, tokens[cursor].line, "unbalanced braces") }
                scopes.removeLast()
                segment = cursor + 1
            case ";": segment = cursor + 1
            default: break
            }
        }
        guard let scope = scopes.last else {
            return nil
        }
        if case let .type(name) = scope {
            return name
        } else {
            throw error(path, tokens[index].line, "nested async func is not supported")
        }
    }

    private static func parameterDeclarations(_ tokens: [Token], path: String, line: Int) throws -> [Parameter] {
        guard !tokens.isEmpty else {
            return []
        }
        var parameters: [Parameter] = []
        var start = 0
        var depth = 0
        for cursor in 0...tokens.count {
            if cursor < tokens.count {
                if ["(", "[", "{"].contains(tokens[cursor].text) { depth += 1 }
                if [")", "]", "}"].contains(tokens[cursor].text) { depth -= 1 }
            }
            guard cursor == tokens.count || (tokens[cursor].text == "," && depth == 0) else { continue }
            guard start < cursor, tokens[start].kind == .identifier else {
                throw error(path, line, "async parameters require named identifiers")
            }
            let typeIndex = tokens[start..<cursor].firstIndex(where: { $0.text == ":" }).map { $0 + 1 }
            let typeName = typeIndex.flatMap { tokens.indices.contains($0) && $0 < cursor && tokens[$0].kind == .identifier ? tokens[$0].text : nil }
            parameters.append(Parameter(name: tokens[start].text, typeName: typeName))
            start = cursor + 1
        }
        return parameters
    }

    private static func lowerAwaits(_ source: String, path: String, firstLine: Int) throws -> String {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        var result = Array(source)
        var replacements: [(Range<Int>, String)] = []
        for index in tokens.indices where tokens[index].text == "await" {
            guard let end = awaitTargetEnd(after: index, tokens: tokens) else {
                throw error(path, firstLine + tokens[index].line - 1, "await requires a task expression")
            }
            if tokens[(index + 1)...end].contains(where: { $0.text == "await" }) {
                throw error(path, firstLine + tokens[index].line - 1, "move nested await expressions into separate statements")
            }
            let target = String(Array(source)[tokens[index + 1].startOffset..<tokens[end].endOffset])
            replacements.append((tokens[index].startOffset..<tokens[end].endOffset, "__adaAwait(\(target))"))
        }
        for (range, replacement) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: Array(replacement))
        }
        return String(result)
    }

    private static func awaitTargetEnd(after index: Int, tokens: [Token]) -> Int? {
        var cursor = index + 1
        guard tokens.indices.contains(cursor), tokens[cursor].kind == .identifier else {
            return nil
        }
        while tokens.indices.contains(cursor + 2), tokens[cursor + 1].text == ".", tokens[cursor + 2].kind == .identifier {
            cursor += 2
        }
        if tokens.indices.contains(cursor + 1), tokens[cursor + 1].text == "(" {
            guard let end = closing(cursor + 1, tokens: tokens, open: "(", close: ")") else {
                return nil
            }
            cursor = end
        }
        return cursor
    }

    private static func closing(_ opening: Int, tokens: [Token], open: String, close: String) -> Int? {
        var depth = 0
        for index in opening..<tokens.count {
            if tokens[index].text == open { depth += 1 }
            if tokens[index].text == close {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }
        return nil
    }

    private static func error(_ path: String, _ line: Int, _ message: String) -> AdaScriptAsyncSyntaxError {
        .init(path: path, line: line, message: message)
    }
}
