/// Suspension policy declared at the AdaScript type, independent of parameter names.
public enum AdaScriptNonSendableTypes {
    /// Returns classes, structs, and enums annotated with `@nonsendable`.
    public static func declared(in source: String, path: String) throws -> Set<String> {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        var names = Set<String>()

        for index in tokens.indices where tokens[index].text == "@" {
            guard tokens.indices.contains(index + 1), tokens[index + 1].text == "nonsendable" else {
                continue
            }
            var cursor = index + 2
            while tokens.indices.contains(cursor), tokens[cursor].text == "@" {
                cursor += 2
                if tokens.indices.contains(cursor), tokens[cursor].text == "(" {
                    guard let end = closingParenthesis(at: cursor, tokens: tokens) else {
                        throw AdaScriptAsyncSyntaxError(path: path, line: tokens[index].line, message: "unterminated annotation after @nonsendable")
                    }
                    cursor = end + 1
                }
            }
            guard tokens.indices.contains(cursor + 1),
                  ["class", "struct", "enum"].contains(tokens[cursor].text),
                  tokens[cursor + 1].kind == .identifier else {
                throw AdaScriptAsyncSyntaxError(path: path, line: tokens[index].line, message: "@nonsendable must annotate a type declaration")
            }
            names.insert(tokens[cursor + 1].text)
        }
        return names
    }

    private static func closingParenthesis(at opening: Int, tokens: [Token]) -> Int? {
        var depth = 0
        for index in opening..<tokens.count {
            if tokens[index].text == "(" { depth += 1 }
            if tokens[index].text == ")" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }
        return nil
    }
}
