extension GravityDocumentAnalyzer {
    static func annotationNames(before declarationIndex: Int, in tokens: [GravityToken]) -> Set<String> {
        Set(annotationTokens(before: declarationIndex, in: tokens).map(\.text))
    }

    static func annotationTokens(before declarationIndex: Int, in tokens: [GravityToken]) -> [GravityToken] {
        guard declarationIndex > 0 else {
            return []
        }
        var annotations: [GravityToken] = []
        var cursor = declarationIndex - 1
        var parenthesisDepth = 0
        while cursor >= 0 {
            let token = tokens[cursor]
            if token.text == ")" {
                parenthesisDepth += 1
            } else if token.text == "(" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
            } else if parenthesisDepth == 0,
                token.kind == .identifier,
                cursor > 0,
                tokens[cursor - 1].text == "@" {
                annotations.append(token)
                cursor -= 1
            } else if parenthesisDepth == 0,
                token.text == ";" || token.text == "}" || typeKeywordNames.contains(token.text) {
                break
            }
            cursor -= 1
        }
        return annotations.reversed()
    }

    private static let typeKeywordNames: Set<String> = ["class", "enum", "struct"]
}
