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

/// Collects AdaEngine callback and suspension metadata. Gravity owns the
/// async grammar, AST lowering, and call effect diagnostics.
public enum AdaScriptAsyncDeclarationScanner {
    private enum Scope {
        case type(String)
        case other
    }

    public static func declarations(
        in source: String,
        path: String,
        nonSendableTypes: Set<String> = []
    ) throws -> [AdaScriptAsyncDeclaration] {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        let markedTypes = try nonSendableTypes.union(AdaScriptNonSendableTypes.declared(in: source, path: path))
        var result: [AdaScriptAsyncDeclaration] = []

        for index in tokens.indices where tokens[index].text == "async" {
            let token = tokens[index]
            guard tokens.indices.contains(index + 3), tokens[index + 1].text == "func",
                  tokens[index + 2].kind == .identifier, tokens[index + 3].text == "(",
                  let close = closing(index + 3, tokens: tokens, open: "(", close: ")") else {
                throw error(path, token.line, "expected 'async func name(...)'")
            }
            let ownerType = try enclosingType(at: index, tokens: tokens, path: path)
            if let ownerType, markedTypes.contains(ownerType) {
                throw error(path, token.line, "async method captures @nonsendable type '\(ownerType)'")
            }
            for parameter in parameters(in: tokens[(index + 4)..<close]) {
                if let typeName = parameter.typeName, markedTypes.contains(typeName) {
                    throw error(path, token.line, "async parameter '\(parameter.name)' has @nonsendable type '\(typeName)'")
                }
            }
            result.append(.init(name: tokens[index + 2].text, ownerType: ownerType, line: token.line))
        }
        return result
    }

    private static func enclosingType(at index: Int, tokens: [Token], path: String) throws -> String? {
        var scopes: [Scope] = []
        var segment = 0
        for cursor in 0..<index {
            switch tokens[cursor].text {
            case "{":
                let declaration = tokens[segment..<cursor]
                if let typeIndex = declaration.firstIndex(where: { ["class", "struct", "enum"].contains($0.text) }),
                   tokens.indices.contains(typeIndex + 1), tokens[typeIndex + 1].kind == .identifier {
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
        }
        throw error(path, tokens[index].line, "nested async func is not supported")
    }

    private static func parameters(in tokens: ArraySlice<Token>) -> [(name: String, typeName: String?)] {
        guard !tokens.isEmpty else {
            return []
        }
        let items = Array(tokens)
        var result: [(name: String, typeName: String?)] = []
        var start = 0
        var depth = 0
        for cursor in 0...items.count {
            if cursor < items.count {
                if ["(", "[", "{"].contains(items[cursor].text) { depth += 1 }
                if [")", "]", "}"].contains(items[cursor].text) { depth -= 1 }
            }
            guard cursor == items.count || (items[cursor].text == "," && depth == 0) else { continue }
            if start < cursor, items[start].kind == .identifier {
                let typeIndex = items[start..<cursor].firstIndex(where: { $0.text == ":" }).map { $0 + 1 }
                let typeName = typeIndex.flatMap { $0 < cursor && items[$0].kind == .identifier ? items[$0].text : nil }
                result.append((items[start].text, typeName))
            }
            start = cursor + 1
        }
        return result
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
