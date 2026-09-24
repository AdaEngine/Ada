import AdaScriptCompilerCore
import Foundation

struct GravityParsedDocument: Sendable {
    var analysis: GravityDocumentAnalysis
    var inferredTypes: [String: String]
    var tokens: [GravityToken]
    var typeRegions: [GravityTypeRegion]
}

struct GravityTypeRegion: Sendable {
    var annotations: Set<String>
    var closeBraceIndex: Int
    var implicitTypes: [String: String]
    var openBraceIndex: Int
    var symbol: GravitySymbol
}

struct GravityDocumentAnalyzer {
    static func parse(_ text: String, projectTypeChecking: AdaScriptTypeCheckingMode = .dynamic) -> GravityParsedDocument {
        var lexer = GravityLexer(source: text)
        let lexResult = lexer.lex()
        let tokens = lexResult.tokens.filter { $0.kind != .comment }
        let sharedAnalysis = AdaScriptAnalyzer.analyze(source: text)
        let sharedInferredTypes = sharedAnalysis.inferredTypes.mapValues(\.displayName)
        let typeRegions = parseTypeRegions(tokens, inferredTypes: sharedInferredTypes)
        let symbols = parseGlobalSymbols(tokens, typeRegions: typeRegions)
        let parsedImports = GravityImportParser.parse(tokens)
        let typeDiagnostics = sharedAnalysis.typeIssues
            .filter { _ in projectTypeChecking == .strict || sharedAnalysis.syntax.isStrict }
            .map(gravityDiagnostic)
        return GravityParsedDocument(
            analysis: GravityDocumentAnalysis(
                diagnostics: lexResult.diagnostics + parsedImports.diagnostics
                    + duplicatePropertyDiagnostics(typeRegions, tokens: tokens)
                    + declarationAnnotationDiagnostics(typeRegions, tokens: tokens)
                    + typeDiagnostics,
                imports: parsedImports.imports,
                symbols: symbols
            ),
            inferredTypes: sharedInferredTypes,
            tokens: lexResult.tokens,
            typeRegions: typeRegions
        )
    }

    static func typeContaining(_ position: GravitySourcePosition, in regions: [GravityTypeRegion]) -> GravitySymbol? {
        regions.first { region in
            region.symbol.range.start <= position && position <= region.symbol.range.end
        }?
        .symbol
    }

    private static func duplicatePropertyDiagnostics(_ regions: [GravityTypeRegion], tokens: [GravityToken]) -> [GravityDiagnostic] {
        let staticProperties = Set(
            tokens.indices.compactMap { index -> GravitySourceRange? in
                guard tokens[index].text == "var" || tokens[index].text == "const", index + 1 < tokens.count else {
                    return nil
                }
                var cursor = index - 1
                while cursor >= 0, ["static", "private", "public", "extern"].contains(tokens[cursor].text) {
                    if tokens[cursor].text == "static" {
                        return tokens[index + 1].range
                    }
                    cursor -= 1
                }
                return nil
            }
        )
        return regions.flatMap { region in
            var names: Set<String> = []
            return region.symbol.members.compactMap { member -> GravityDiagnostic? in
                let key = staticProperties.contains(member.selectionRange) ? "$\(member.name)" : member.name
                guard member.kind == .property, !names.insert(key).inserted else {
                    return nil
                }
                return GravityDiagnostic(
                    message: "Duplicate property '\(member.name)' in '\(region.symbol.name)'",
                    range: member.selectionRange
                )
            }
        }
    }

    private static func declarationAnnotationDiagnostics(_ regions: [GravityTypeRegion], tokens: [GravityToken]) -> [GravityDiagnostic] {
        regions.flatMap { region -> [GravityDiagnostic] in
            guard let declarationIndex = tokens.firstIndex(where: { $0.range.start == region.symbol.range.start }) else {
                return []
            }
            let annotations = annotationTokens(before: declarationIndex, in: tokens)
            let names = Set(annotations.map(\.text))
            var diagnostics = annotations.compactMap { annotation -> GravityDiagnostic? in
                let requiredKind: String?
                switch annotation.text {
                case "component", "replicated_component", "resource", "network_command":
                    requiredKind = "struct"
                case "system", "scriptable", "tool":
                    requiredKind = "class"
                case "previewable" where !names.contains("view"):
                    return GravityDiagnostic(message: "@previewable requires @view", range: annotation.range)
                default:
                    requiredKind = nil
                }
                guard let requiredKind, region.symbol.kind != (requiredKind == "class" ? .class : .struct) else {
                    return nil
                }
                return GravityDiagnostic(
                    message: "@\(annotation.text) requires a \(requiredKind); change '\(kindDescription(region.symbol.kind))' to '\(requiredKind)'",
                    range: annotation.range
                )
            }
            let declarationAnnotations = annotations.filter {
                ["component", "replicated_component", "resource", "network_command", "system", "scriptable", "tool", "view"].contains($0.text)
            }
            if let first = declarationAnnotations.first {
                diagnostics += declarationAnnotations.dropFirst().map { annotation in
                    GravityDiagnostic(
                        message: "@\(annotation.text) cannot be combined with @\(first.text) on \(region.symbol.name)",
                        range: annotation.range
                    )
                }
            }
            return diagnostics
        }
    }

    private static func parseTypeRegions(
        _ tokens: [GravityToken],
        inferredTypes: [String: String]
    ) -> [GravityTypeRegion] {
        var regions: [GravityTypeRegion] = []
        var index = 0
        while index < tokens.count {
            guard
                let kind = typeKind(for: tokens[index].text),
                let nameIndex = nextIdentifier(after: index, in: tokens),
                let openBraceIndex = nextToken("{", after: nameIndex, in: tokens)
            else {
                index += 1
                continue
            }
            let matchedCloseBraceIndex = matchingCloseBrace(for: openBraceIndex, in: tokens)
            let memberUpperBound = matchedCloseBraceIndex ?? tokens.count
            let closeBraceIndex = matchedCloseBraceIndex ?? (tokens.count - 1)
            let annotations = annotationNames(before: index, in: tokens)

            let members = parseDeclarations(
                tokens,
                range: (openBraceIndex + 1)..<memberUpperBound,
                baseDepth: 0,
                memberContext: true
            )
            let nameToken = tokens[nameIndex]
            let symbol = GravitySymbol(
                name: nameToken.text,
                kind: kind,
                detail: "AdaScript \(kindDescription(kind))",
                range: GravitySourceRange(start: tokens[index].range.start, end: tokens[closeBraceIndex].range.end),
                selectionRange: nameToken.range,
                members: members
            )
            regions.append(
                GravityTypeRegion(
                    annotations: annotations,
                    closeBraceIndex: closeBraceIndex,
                    implicitTypes: inferredTypes,
                    openBraceIndex: openBraceIndex,
                    symbol: symbol
                )
            )
            index = memberUpperBound
        }
        return regions
    }

    private static func parseGlobalSymbols(_ tokens: [GravityToken], typeRegions: [GravityTypeRegion]) -> [GravitySymbol] {
        var symbols = typeRegions.map(\.symbol)
        var excludedIndices = Set<Int>()
        for region in typeRegions {
            excludedIndices.formUnion(region.openBraceIndex...region.closeBraceIndex)
        }
        symbols += parseDeclarations(
            tokens,
            range: tokens.indices,
            baseDepth: 0,
            memberContext: false,
            excludedIndices: excludedIndices
        )
        return symbols.uniqued(on: { "\($0.kind.rawValue):\($0.name)" })
    }

    private static func parseDeclarations(
        _ tokens: [GravityToken],
        range: Range<Int>,
        baseDepth: Int,
        memberContext: Bool,
        excludedIndices: Set<Int> = []
    ) -> [GravitySymbol] {
        var braceDepth = baseDepth
        var symbols: [GravitySymbol] = []
        var index = range.lowerBound
        while index < range.upperBound {
            let token = tokens[index]
            if excludedIndices.contains(index) {
                index += 1
                continue
            }
            if token.text == "{" {
                braceDepth += 1
                index += 1
                continue
            }
            if token.text == "}" {
                braceDepth = max(baseDepth, braceDepth - 1)
                index += 1
                continue
            }
            guard
                braceDepth == baseDepth,
                let nameIndex = nextIdentifier(after: index, upperBound: range.upperBound, in: tokens)
            else {
                index += 1
                continue
            }

            if let symbol = declarationSymbol(
                keyword: token.text,
                nameToken: tokens[nameIndex],
                memberContext: memberContext,
                isAsync: token.text == "func" && index > 0 && tokens[index - 1].text == "async"
            ) {
                symbols.append(symbol)
            }
            index += 1
        }
        return symbols
    }

    private static func declarationSymbol(
        keyword: String,
        nameToken: GravityToken,
        memberContext: Bool,
        isAsync: Bool
    ) -> GravitySymbol? {
        let kind: GravitySymbolKind
        let detail: String
        switch keyword {
        case "func":
            kind = memberContext ? .method : .function
            detail = isAsync
                ? (memberContext ? "AdaScript async method" : "AdaScript async function")
                : (memberContext ? "AdaScript method" : "AdaScript function")
        case "var":
            kind = memberContext ? .property : .variable
            detail = memberContext ? "AdaScript property" : "AdaScript variable"
        case "const":
            kind = memberContext ? .property : .constant
            detail = memberContext ? "AdaScript property" : "AdaScript constant"
        default:
            return nil
        }
        return GravitySymbol(name: nameToken.text, kind: kind, detail: detail, range: nameToken.range)
    }

    private static func gravityDiagnostic(_ issue: AdaScriptTypeIssue) -> GravityDiagnostic {
        GravityDiagnostic(
            message: issue.message,
            range: GravitySourceRange(
                start: GravitySourcePosition(
                    line: issue.range.start.line,
                    utf16Column: issue.range.start.utf16Column
                ),
                end: GravitySourcePosition(
                    line: issue.range.end.line,
                    utf16Column: issue.range.end.utf16Column
                )
            )
        )
    }

    private static func typeKind(for text: String) -> GravitySymbolKind? {
        switch text {
        case "class": .class
        case "enum": .enum
        case "struct": .struct
        default: nil
        }
    }

    private static func kindDescription(_ kind: GravitySymbolKind) -> String {
        switch kind {
        case .class: "class"
        case .enum: "enum"
        case .struct: "struct"
        default: "type"
        }
    }

    private static func nextIdentifier(after index: Int, upperBound: Int? = nil, in tokens: [GravityToken]) -> Int? {
        let candidate = index + 1
        let bound = upperBound ?? tokens.count
        guard candidate < bound, tokens[candidate].kind == .identifier else {
            return nil
        }
        return candidate
    }

    private static func nextToken(_ text: String, after index: Int, in tokens: [GravityToken]) -> Int? {
        var candidate = index + 1
        while candidate < tokens.count {
            if tokens[candidate].text == text {
                return candidate
            }
            if tokens[candidate].text == ";" || tokens[candidate].text == "}" {
                return nil
            }
            candidate += 1
        }
        return nil
    }

    private static func matchingCloseBrace(for openBraceIndex: Int, in tokens: [GravityToken]) -> Int? {
        var depth = 0
        for index in openBraceIndex..<tokens.count {
            if tokens[index].text == "{" {
                depth += 1
            } else if tokens[index].text == "}" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }
        return nil
    }
}

extension Sequence {
    func uniqued<Key: Hashable>(on key: (Element) -> Key) -> [Element] {
        var seen: Set<Key> = []
        return filter { seen.insert(key($0)).inserted }
    }
}
