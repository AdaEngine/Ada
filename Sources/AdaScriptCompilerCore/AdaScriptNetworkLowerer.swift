/// Lowers typed network declarations into VM constructors and optional RPC handlers.
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
            guard tokens[index].text == "@", ["network_command", "rpc"].contains(tokens[index + 1].text) else {
                index += 1
                continue
            }
            let isRPC = tokens[index + 1].text == "rpc"
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
            let name: String
            let parameters: String
            let endIndex: Int
            var handlerBody: String?
            if isRPC {
                guard
                    tokens.indices.contains(declarationIndex + 2),
                    tokens[declarationIndex].text == "func",
                    tokens[declarationIndex + 1].kind == .identifier,
                    tokens[declarationIndex + 2].text == "(",
                    let closing = matchingIndex(openingAt: declarationIndex + 2, opening: "(", closing: ")", tokens: tokens),
                    tokens.indices.contains(closing + 1)
                else {
                    index += 2
                    continue
                }
                name = tokens[declarationIndex + 1].text
                parameters = rpcParameters(in: (declarationIndex + 3)..<closing, tokens: tokens).joined(separator: ", ")
                if tokens[closing + 1].text == "{" {
                    guard let bodyEnd = matchingIndex(openingAt: closing + 1, opening: "{", closing: "}", tokens: tokens) else {
                        index += 2
                        continue
                    }
                    endIndex = bodyEnd
                    if bodyEnd > closing + 2 {
                        handlerBody = String(characters[tokens[closing + 1].endOffset..<tokens[bodyEnd].startOffset])
                    }
                } else {
                    endIndex = closing + 1
                }
            } else {
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
                name = tokens[declarationIndex + 1].text
                parameters = networkFields(in: (declarationIndex + 3)..<bodyEnd, tokens: tokens).joined(separator: ", ")
                endIndex = bodyEnd
            }
            let constructor = "func \(name)(\(parameters)) { return __adaNetworkFactory.make(\"\(name)\", [\(parameters)]); }"
            let lowered = handlerBody.map {
                "\(constructor) func __ada_rpc_handler_\(name)(source, \(parameters)) { \($0) }"
            } ?? constructor
            replacements.append(
                Replacement(
                    endOffset: tokens[endIndex].endOffset,
                    source: lowered,
                    startOffset: tokens[index].startOffset
                )
            )
            index = endIndex + 1
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

    private static func rpcParameters(in range: Range<Int>, tokens: [Token]) -> [String] {
        var names: [String] = []
        var index = range.lowerBound
        while index + 2 < range.upperBound {
            guard tokens[index].text == "@", tokens[index + 1].text == "network_field" else {
                index += 1
                continue
            }
            let annotationEnd: Int
            if tokens[index + 2].text == "(",
                let closing = matchingIndex(openingAt: index + 2, opening: "(", closing: ")", tokens: tokens) {
                annotationEnd = closing
            } else {
                index += 2
                continue
            }
            if tokens.indices.contains(annotationEnd + 1) {
                names.append(tokens[annotationEnd + 1].text)
            }
            index = annotationEnd + 2
        }
        return names
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
