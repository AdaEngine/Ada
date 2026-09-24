enum GravityUnresolvedValueAnalyzer {
    private struct ScopedName {
        var name: String
        var tokenRange: Range<Int>

        func isVisible(_ name: String, at index: Int) -> Bool {
            self.name == name && tokenRange.contains(index)
        }
    }

    static func diagnostics(
        tokens: [GravityToken],
        symbols: [GravitySymbol],
        workspaceSymbols: [GravitySymbol],
        imports: [GravityImport],
        hostConstructors: [GravityHostConstructor]
    ) -> [GravityDiagnostic] {
        let tokens = tokens.filter { $0.kind != .comment }
        let (enclosingBrace, braceEnds) = braceScopes(in: tokens)
        var declared = Set(symbols.map(\.name) + workspaceSymbols.map(\.name))
        declared.formUnion(hostConstructors.map(\.name))
        declared.formUnion(GravityBuiltins.globalCandidates.map(\.label))
        declared.formUnion(["self", "super", "true", "false", "null", "undefined"])
        for scriptImport in imports {
            declared.formUnion(scriptImport.names)
            if let namespace = scriptImport.namespace {
                declared.insert(namespace)
            }
        }

        var scoped: [ScopedName] = []
        for index in tokens.indices {
            if ["var", "const", "func"].contains(tokens[index].text),
                index + 1 < tokens.count, tokens[index + 1].kind == .identifier,
                let openBrace = enclosingBrace[index] {
                scoped.append(ScopedName(
                    name: tokens[index + 1].text,
                    tokenRange: (index + 1)..<(braceEnds[openBrace] ?? tokens.count)
                ))
            }
            if tokens[index].text == "func" {
                collectParameters(after: index, tokens: tokens, braceEnds: braceEnds, into: &scoped)
            }
            if tokens[index].text == "for" {
                collectLoopVariable(after: index, tokens: tokens, braceEnds: braceEnds, into: &scoped)
            }
        }

        let valuePrefixes: Set<String> = ["(", "[", ",", "=", "return", "in", "await", "not", "+", "-", "*", "/", "!", "&&", "||"]
        return tokens.indices.compactMap { index in
            let token = tokens[index]
            let isMember = symbols.contains { symbol in
                symbol.range.contains(token.range.start) && symbol.members.contains { $0.name == token.text }
            }
            guard token.kind == .identifier, !declared.contains(token.text), !isMember,
                !scoped.contains(where: { $0.isVisible(token.text, at: index) }), token.text.first?.isUppercase != true,
                index > 0,
                valuePrefixes.contains(tokens[index - 1].text) || isNamedArgumentValue(at: index, tokens: tokens) else {
                return nil
            }
            let next = index + 1 < tokens.count ? tokens[index + 1].text : nil
            guard next != ":", next != "(", next != "in",
                !keywords.contains(token.text), tokens[index - 1].text != "@" else {
                return nil
            }
            return GravityDiagnostic(message: "Unknown value '\(token.text)'", range: token.range)
        }
    }

    private static func braceScopes(in tokens: [GravityToken]) -> (enclosing: [Int?], ends: [Int: Int]) {
        var enclosing = Array<Int?>(repeating: nil, count: tokens.count)
        var ends: [Int: Int] = [:]
        var stack: [Int] = []
        for index in tokens.indices {
            enclosing[index] = stack.last
            if tokens[index].text == "{" {
                stack.append(index)
            } else if tokens[index].text == "}", let open = stack.popLast() {
                ends[open] = index
            }
        }
        for open in stack { ends[open] = tokens.count }
        return (enclosing, ends)
    }

    private static func isNamedArgumentValue(at index: Int, tokens: [GravityToken]) -> Bool {
        guard tokens[index - 1].text == ":" else { return false }
        var nestedParentheses = 0
        for candidate in stride(from: index - 2, through: 0, by: -1) {
            let token = tokens[candidate].text
            if token == ")" {
                nestedParentheses += 1
            } else if token == "(" {
                if nestedParentheses == 0 {
                    guard candidate > 0, tokens[candidate - 1].kind == .identifier else { return false }
                    return candidate < 2 || tokens[candidate - 2].text != "func"
                }
                nestedParentheses -= 1
            } else if token == "{" && nestedParentheses == 0 {
                return false
            }
        }
        return false
    }

    private static func collectParameters(
        after functionIndex: Int,
        tokens: [GravityToken],
        braceEnds: [Int: Int],
        into scoped: inout [ScopedName]
    ) {
        guard functionIndex + 2 < tokens.count, tokens[functionIndex + 2].text == "(" else {
            return
        }
        let open = functionIndex + 2
        var depth = 1
        var expectsName = true
        var names: [String] = []
        var cursor = open + 1
        while cursor < tokens.count, depth > 0 {
            let token = tokens[cursor]
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                depth -= 1
            } else if depth == 1, token.text == "," {
                expectsName = true
            } else if depth == 1, expectsName, token.kind == .identifier {
                names.append(token.text)
                expectsName = false
            }
            cursor += 1
        }
        var body = cursor
        while body < tokens.count, !["{", ";", "}"].contains(tokens[body].text) {
            body += 1
        }
        let end = body < tokens.count && tokens[body].text == "{" ? braceEnds[body] ?? tokens.count : cursor
        scoped += names.map { ScopedName(name: $0, tokenRange: open..<end) }
    }

    private static func collectLoopVariable(
        after loopIndex: Int,
        tokens: [GravityToken],
        braceEnds: [Int: Int],
        into scoped: inout [ScopedName]
    ) {
        guard loopIndex + 2 < tokens.count, tokens[loopIndex + 1].text == "(" else {
            return
        }
        let candidate = tokens[loopIndex + 2].text == "var" ? loopIndex + 3 : loopIndex + 2
        if candidate + 1 < tokens.count, tokens[candidate].kind == .identifier, tokens[candidate + 1].text == "in" {
            let body = tokens.indices.dropFirst(candidate + 2).first { tokens[$0].text == "{" || tokens[$0].text == ";" }
            let end = body.flatMap { tokens[$0].text == "{" ? braceEnds[$0] : nil } ?? tokens.count
            scoped.append(ScopedName(name: tokens[candidate].text, tokenRange: candidate..<end))
        }
    }

    private static let keywords: Set<String> = [
        "and", "async", "await", "break", "case", "continue", "default", "else", "false", "for", "if", "in", "is", "not", "null", "or", "return", "switch",
        "true", "undefined", "while",
    ]
}
