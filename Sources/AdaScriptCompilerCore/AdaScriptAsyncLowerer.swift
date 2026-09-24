import Foundation

public struct AdaScriptAsyncSyntaxError: Error, Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let line: Int
    public let message: String

    public var description: String { "\(path):\(line): \(message)" }
}

/// Lowers explicit AdaScript async functions to VM fibers before Gravity compilation.
public enum AdaScriptAsyncLowerer {
    private struct Declaration {
        let range: Range<Int>
        let body: Range<Int>
        let name: String
        let parameters: String
        let arguments: [String]
        let receiver: String
        let line: Int
    }

    public static func globalFunctionNames(source: String, path: String) throws -> Set<String> {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        let characters = Array(source)
        var names = Set<String>()
        for index in tokens.indices where tokens[index].text == "async" {
            let declaration = try parse(at: index, tokens: tokens, characters: characters, path: path)
            if declaration.receiver.isEmpty { names.insert(declaration.name) }
        }
        return names
    }

    public static func lower(source: String, path: String, globalAsyncNames: Set<String> = []) throws -> String {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        let characters = Array(source)
        var declarations: [Declaration] = []
        var covered = Set<Int>()

        for index in tokens.indices where tokens[index].text == "async" {
            guard !covered.contains(index) else { continue }
            let declaration = try parse(at: index, tokens: tokens, characters: characters, path: path)
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
            let replacement = """
            func \(declaration.name)(\(declaration.parameters)) {
                \(capturedReceiver)var __ada_task = __AdaTask();
                __ada_task.fiber = Fiber.create({
                    __ada_task.value = \(call);
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

    private static func parse(at index: Int, tokens: [Token], characters: [Character], path: String) throws -> Declaration {
        let token = tokens[index]
        guard tokens.indices.contains(index + 3), tokens[index + 1].text == "func",
              tokens[index + 2].kind == .identifier, tokens[index + 3].text == "(",
              let closeParameters = closing(index + 3, tokens: tokens, open: "(", close: ")"),
              tokens.indices.contains(closeParameters + 1), tokens[closeParameters + 1].text == "{",
              let closeBody = closing(closeParameters + 1, tokens: tokens, open: "{", close: "}") else {
            throw error(path, token.line, "expected 'async func name(...) { ... }'")
        }
        let method = try isMethod(at: index, tokens: tokens, path: path)
        let name = tokens[index + 2].text
        if method && ["update", "fixedUpdate", "ready", "event", "body", "destroy"].contains(name) {
            throw error(path, token.line, "engine lifecycle method '\(name)' must remain synchronous")
        }
        let arguments = try parameterNames(Array(tokens[(index + 4)..<closeParameters]), path: path, line: token.line)
        if arguments.contains("context") {
            throw error(path, token.line, "borrowed callback context cannot enter an async func")
        }
        return Declaration(
            range: token.startOffset..<tokens[closeBody].endOffset,
            body: tokens[closeParameters + 1].startOffset..<tokens[closeBody].endOffset,
            name: name,
            parameters: String(characters[tokens[index + 3].endOffset..<tokens[closeParameters].startOffset]),
            arguments: arguments,
            receiver: method ? "__ada_receiver." : "",
            line: token.line
        )
    }

    private static func validateGlobalAsyncCalls(
        declarations: [Declaration],
        globalAsyncNames: Set<String>,
        tokens: [Token],
        path: String
    ) throws {
        let globalNames = globalAsyncNames.union(declarations.filter { $0.receiver.isEmpty }.map(\.name))
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
            if let close = closing(index + 1, tokens: tokens, open: "(", close: ")"), close > index + 2,
               tokens[(index + 2)..<close].contains(where: { $0.text == "context" }) {
                throw error(path, tokens[index].line, "borrowed callback context cannot be passed to an async func")
            }
        }
    }

    private static func isMethod(at index: Int, tokens: [Token], path: String) throws -> Bool {
        var scopes: [Bool] = []
        var segment = 0
        for cursor in 0..<index {
            switch tokens[cursor].text {
            case "{":
                scopes.append(tokens[segment..<cursor].contains(where: { $0.text == "class" }))
                segment = cursor + 1
            case "}":
                guard !scopes.isEmpty else { throw error(path, tokens[cursor].line, "unbalanced braces") }
                scopes.removeLast()
                segment = cursor + 1
            case ";": segment = cursor + 1
            default: break
            }
        }
        if scopes.last == false { throw error(path, tokens[index].line, "nested async func is not supported") }
        return scopes.last == true
    }

    private static func parameterNames(_ tokens: [Token], path: String, line: Int) throws -> [String] {
        guard !tokens.isEmpty else {
            return []
        }
        var names: [String] = []
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
            names.append(tokens[start].text)
            start = cursor + 1
        }
        return names
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
