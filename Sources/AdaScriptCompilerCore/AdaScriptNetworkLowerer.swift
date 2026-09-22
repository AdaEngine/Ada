/// Lowers typed AdaScript network-model declarations into VM constructor functions.
public enum AdaScriptNetworkLowerer {
    private struct Replacement {
        let endOffset: Int
        let source: String
        let startOffset: Int
    }

    public static func lower(source: String) -> String {
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        let characters = Array(source)
        var replacements: [Replacement] = []
        var index = 0
        while index + 1 < tokens.count {
            guard tokens[index].text == "@", tokens[index + 1].text == "network_command" else {
                index += 1
                continue
            }
            let declarationIndex: Int
            if tokens.indices.contains(index + 2), tokens[index + 2].text == "(" {
                guard let closing = matchingIndex(openingAt: index + 2, opening: "(", closing: ")", tokens: tokens) else {
                    index += 2
                    continue
                }
                declarationIndex = closing + 1
            } else {
                declarationIndex = index + 2
            }
            guard
                tokens.indices.contains(declarationIndex + 2),
                tokens[declarationIndex].text == "struct",
                tokens[declarationIndex + 1].kind == .identifier,
                tokens[declarationIndex + 2].text == "{",
                let bodyEnd = matchingIndex(openingAt: declarationIndex + 2, opening: "{", closing: "}", tokens: tokens)
            else {
                index += 2
                continue
            }
            let name = tokens[declarationIndex + 1].text
            let fields = networkFields(in: (declarationIndex + 3)..<bodyEnd, tokens: tokens)
            let parameters = fields.joined(separator: ", ")
            replacements.append(
                Replacement(
                    endOffset: tokens[bodyEnd].endOffset,
                    source: "func \(name)(\(parameters)) { return __adaNetworkFactory.make(\"\(name)\", [\(parameters)]); }",
                    startOffset: tokens[index].startOffset
                )
            )
            index = bodyEnd + 1
        }

        var result = characters
        for replacement in replacements.sorted(by: { $0.startOffset > $1.startOffset }) {
            result.replaceSubrange(replacement.startOffset..<replacement.endOffset, with: Array(replacement.source))
        }
        return String(result)
    }

    private static func networkFields(in range: Range<Int>, tokens: [Token]) -> [String] {
        var fields: [String] = []
        var depth = 0
        var index = range.lowerBound
        while index < range.upperBound {
            if tokens[index].text == "{" || tokens[index].text == "(" || tokens[index].text == "[" {
                depth += 1
            } else if tokens[index].text == "}" || tokens[index].text == ")" || tokens[index].text == "]" {
                depth -= 1
            } else if depth == 0,
                tokens[index].text == "var",
                tokens.indices.contains(index + 1),
                tokens[index + 1].kind == .identifier {
                fields.append(tokens[index + 1].text)
            }
            index += 1
        }
        return fields
    }

    private static func matchingIndex(
        openingAt openingIndex: Int,
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
