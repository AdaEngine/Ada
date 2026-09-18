struct GravityImportParser {
    static func parse(_ tokens: [GravityToken]) -> (diagnostics: [GravityDiagnostic], imports: [GravityImport]) {
        var diagnostics: [GravityDiagnostic] = []
        var imports: [GravityImport] = []
        var index = 0
        while index < tokens.count {
            guard tokens[index].text == "import" else {
                index += 1
                continue
            }
            let result = parseImport(tokens, at: index)
            switch result {
            case let .success(scriptImport, nextIndex):
                imports.append(scriptImport)
                index = nextIndex
            case let .failure(diagnostic):
                diagnostics.append(diagnostic)
                index += 1
            }
        }
        return (diagnostics: diagnostics, imports: imports)
    }

    private static func parseImport(_ tokens: [GravityToken], at index: Int) -> ParseResult {
        let startToken = tokens[index]
        var cursor = index + 1
        guard tokens.indices.contains(cursor) else {
            return .failure(diagnostic("Expected import declaration", token: startToken))
        }
        if tokens[cursor].text == "*" {
            return .failure(diagnostic("Namespace imports are not implemented yet", token: startToken))
        }
        guard tokens[cursor].text == "{" else {
            return .failure(diagnostic("Expected '{ ... }' after import", token: startToken))
        }

        let nameResult = parseNames(tokens, after: cursor)
        guard case let .success(names, closingBraceIndex) = nameResult else {
            return .failure(diagnostic("Expected '}' in import declaration", token: startToken))
        }
        cursor = closingBraceIndex + 1
        guard
            tokens.indices.contains(cursor), tokens[cursor].text == "from",
            tokens.indices.contains(cursor + 1), tokens[cursor + 1].kind == .string,
            let path = stringLiteralValue(tokens[cursor + 1].text)
        else {
            return .failure(diagnostic("Expected quoted module path after 'from'", token: startToken))
        }

        let pathToken = tokens[cursor + 1]
        let semicolonIndex = cursor + 2
        guard tokens.indices.contains(semicolonIndex), tokens[semicolonIndex].text == ";" else {
            return .failure(diagnostic("Expected ';' after import", token: pathToken))
        }
        return .success(
            GravityImport(
                names: names,
                path: path,
                range: GravitySourceRange(start: startToken.range.start, end: tokens[semicolonIndex].range.end)
            ),
            semicolonIndex + 1
        )
    }

    private static func parseNames(_ tokens: [GravityToken], after openBraceIndex: Int) -> NameParseResult {
        var cursor = openBraceIndex + 1
        var names: [String] = []
        var expectsIdentifier = true
        while tokens.indices.contains(cursor), tokens[cursor].text != "}" {
            if expectsIdentifier, tokens[cursor].kind == .identifier {
                names.append(tokens[cursor].text)
                expectsIdentifier = false
            } else if !expectsIdentifier, tokens[cursor].text == "," {
                expectsIdentifier = true
            } else {
                return .failure
            }
            cursor += 1
        }
        guard
            !names.isEmpty, !expectsIdentifier,
            tokens.indices.contains(cursor), tokens[cursor].text == "}"
        else {
            return .failure
        }
        return .success(names, cursor)
    }

    private static func diagnostic(_ message: String, token: GravityToken) -> GravityDiagnostic {
        GravityDiagnostic(message: message, range: token.range)
    }

    private static func stringLiteralValue(_ literal: String) -> String? {
        guard literal.count >= 2, literal.first == "\"", literal.last == "\"" else {
            return nil
        }
        return String(literal.dropFirst().dropLast())
    }

    private enum NameParseResult {
        case failure
        case success([String], Int)
    }

    private enum ParseResult {
        case failure(GravityDiagnostic)
        case success(GravityImport, Int)
    }
}
