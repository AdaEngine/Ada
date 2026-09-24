import AdaScriptCompilerCore
import Foundation

public struct GravityLanguageService: Sendable {
    private let hostConstructors: [GravityHostConstructor]
    private let projectTypeChecking: AdaScriptTypeCheckingMode

    public init(
        hostConstructors: [GravityHostConstructor] = [],
        projectTypeChecking: AdaScriptTypeCheckingMode = .dynamic
    ) {
        self.hostConstructors = hostConstructors.sorted { $0.name < $1.name }
        self.projectTypeChecking = projectTypeChecking
    }

    /// Analyzes source without compiling it. Workspace symbols keep imported project names resolvable.
    public func analyze(text: String, workspaceSymbols: [GravitySymbol] = []) -> GravityDocumentAnalysis {
        let parsed = GravityDocumentAnalyzer.parse(text, projectTypeChecking: projectTypeChecking)
        var analysis = parsed.analysis
        analysis.diagnostics += GravityUnresolvedValueAnalyzer.diagnostics(
            tokens: parsed.tokens,
            symbols: analysis.symbols,
            workspaceSymbols: workspaceSymbols,
            imports: analysis.imports,
            hostConstructors: hostConstructors
        )
        return analysis
    }

    public func quickFixes(text: String, range: GravitySourceRange) -> [GravityQuickFix] {
        let parsed = GravityDocumentAnalyzer.parse(text)
        let tokens = parsed.tokens.filter { $0.kind != .comment }
        return parsed.typeRegions.flatMap { region -> [GravityQuickFix] in
            guard
                region.symbol.kind == .class || region.symbol.kind == .struct,
                let declarationIndex = tokens.firstIndex(where: { $0.range.start == region.symbol.range.start })
            else {
                return []
            }
            let replacement = region.symbol.kind == .class ? "struct" : "class"
            let invalidAnnotations: Set<String> = region.symbol.kind == .class
                ? ["component", "replicated_component", "resource", "network_command"]
                : ["system", "scriptable", "tool"]
            return GravityDocumentAnalyzer.annotationTokens(before: declarationIndex, in: tokens).compactMap { annotation in
                guard
                    invalidAnnotations.contains(annotation.text),
                    annotation.range.start <= range.end,
                    range.start <= annotation.range.end,
                    let diagnostic = parsed.analysis.diagnostics.first(where: { $0.range == annotation.range })
                else {
                    return nil
                }
                let keywordRange = GravitySourceRange(
                    start: region.symbol.range.start,
                    end: GravitySourcePosition(
                        line: region.symbol.range.start.line,
                        utf16Column: region.symbol.range.start.utf16Column + (region.symbol.kind == .class ? 5 : 6)
                    )
                )
                return GravityQuickFix(
                    diagnostic: diagnostic,
                    title: "Change to \(replacement)",
                    replacementRange: keywordRange,
                    newText: replacement
                )
            }
        }
    }

    public func semanticTokens(text: String) -> [GravitySemanticToken] {
        GravitySemanticAnalyzer.tokens(in: text)
    }

    public func hover(text: String, position: GravitySourcePosition) -> GravityHover? {
        let parsed = GravityDocumentAnalyzer.parse(text)
        let tokens = parsed.tokens.filter { $0.kind != .comment }
        guard let tokenIndex = tokens.firstIndex(where: { $0.kind == .identifier && $0.range.contains(position) }) else {
            return nil
        }
        let token = tokens[tokenIndex]
        if tokenIndex > 0,
            tokens[tokenIndex - 1].text == "@",
            let annotation = GravityBuiltins.annotationCandidates.first(where: { $0.label == token.text }) {
            return GravityHover(contents: annotation.detail, range: token.range)
        }
        if let receiverPath = Self.receiverPath(beforeMemberAt: tokenIndex, tokens: tokens),
            let receiverType = resolvedType(receiverPath: receiverPath, position: position, parsed: parsed),
            let member = GravityAPICatalog.member(named: token.text, in: receiverType) {
            return GravityHover(contents: member.detail, range: token.range)
        }
        if let constructor = hostConstructors.first(where: { $0.name == token.text }) {
            return GravityHover(contents: constructor.signature, range: token.range)
        }
        let symbols = parsed.analysis.symbols + parsed.analysis.symbols.flatMap(\.members)
        guard let symbol = symbols.first(where: { $0.name == token.text }) else {
            return nil
        }
        return GravityHover(contents: symbol.detail, range: token.range)
    }

    public func signatureHelp(text: String, position: GravitySourcePosition) -> GravitySignatureHelp? {
        let parsed = GravityDocumentAnalyzer.parse(text)
        let tokens = parsed.tokens.filter { $0.kind != .comment && $0.range.start < position }
        var openParentheses: [Int] = []
        for index in tokens.indices {
            if tokens[index].text == "(" {
                openParentheses.append(index)
            } else if tokens[index].text == ")" {
                _ = openParentheses.popLast()
            }
        }
        guard let openIndex = openParentheses.last, openIndex > 0, tokens[openIndex - 1].kind == .identifier else {
            return nil
        }

        var activeParameter = 0
        var nestedDepth = 0
        for token in tokens.dropFirst(openIndex + 1) {
            if token.text == "(" || token.text == "[" || token.text == "{" {
                nestedDepth += 1
            } else if token.text == ")" || token.text == "]" || token.text == "}" {
                nestedDepth = max(0, nestedDepth - 1)
            } else if token.text == ",", nestedDepth == 0 {
                activeParameter += 1
            }
        }
        if let receiverPath = Self.receiverPath(beforeMemberAt: openIndex - 1, tokens: tokens),
            let receiverType = resolvedType(receiverPath: receiverPath, position: position, parsed: parsed),
            let member = GravityAPICatalog.member(named: tokens[openIndex - 1].text, in: receiverType) {
            return GravitySignatureHelp(activeParameter: activeParameter, label: member.detail)
        }
        guard let constructor = hostConstructors.first(where: { $0.name == tokens[openIndex - 1].text }) else {
            return nil
        }
        return GravitySignatureHelp(activeParameter: activeParameter, label: constructor.signature)
    }

    public func completions(
        text: String,
        position: GravitySourcePosition,
        workspaceSymbols: [GravitySymbol] = []
    ) -> [GravityCompletion] {
        guard let context = GravityCompletionContext(text: text, position: position) else {
            return []
        }
        let parsed = GravityDocumentAnalyzer.parse(text)
        guard
            !parsed.tokens.contains(where: { token in
                (token.kind == .comment || token.kind == .string) && token.range.start <= position && position <= token.range.end
            })
        else {
            return []
        }

        let symbols = (parsed.analysis.symbols + workspaceSymbols).uniqued(on: { "\($0.kind.rawValue):\($0.name)" })
        let candidates: [GravityCompletionCandidate]
        if let receiverPath = context.receiverPath {
            candidates = memberCandidates(receiverPath: receiverPath, position: position, parsed: parsed, symbols: symbols)
        } else if context.isAnnotation {
            candidates = GravityBuiltins.annotationCandidates
        } else {
            candidates = GravityBuiltins.globalCandidates
                + hostConstructors.map(hostConstructorCandidate)
                + symbols.map(GravityCompletionCandidate.init(symbol:))
        }

        return
            candidates
            .filter { context.prefix.isEmpty || $0.label.localizedCaseInsensitiveContains(context.prefix) }
            .uniqued(on: \.label)
            .sorted { lhs, rhs in
                let prefix = context.prefix.lowercased()
                let lhsStartsWithPrefix = lhs.label.lowercased().hasPrefix(prefix)
                let rhsStartsWithPrefix = rhs.label.lowercased().hasPrefix(prefix)
                if lhsStartsWithPrefix != rhsStartsWithPrefix {
                    return lhsStartsWithPrefix
                }
                if lhs.sortText != rhs.sortText {
                    return lhs.sortText < rhs.sortText
                }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            .map { candidate in
                GravityCompletion(
                    label: candidate.label,
                    detail: candidate.detail,
                    insertText: candidate.insertText,
                    kind: candidate.kind,
                    replacementRange: context.replacementRange,
                    sortText: candidate.sortText
                )
            }
    }

    private func hostConstructorCandidate(_ constructor: GravityHostConstructor) -> GravityCompletionCandidate {
        GravityCompletionCandidate(
            detail: constructor.signature,
            insertText: "\(constructor.name)()",
            kind: .class,
            label: constructor.name,
            sortText: "18"
        )
    }

    private func memberCandidates(
        receiverPath: [String],
        position: GravitySourcePosition,
        parsed: GravityParsedDocument,
        symbols: [GravitySymbol]
    ) -> [GravityCompletionCandidate] {
        guard !receiverPath.isEmpty else {
            return []
        }

        guard let inferredType = resolvedType(receiverPath: receiverPath, position: position, parsed: parsed) else {
            return []
        }

        if let builtins = GravityBuiltins.members[inferredType] {
            return builtins
        }
        return symbols.first(where: { $0.name == inferredType && !$0.members.isEmpty })?.members.map(GravityCompletionCandidate.init(symbol:)) ?? []
    }

    private func resolvedType(
        receiverPath: [String],
        position: GravitySourcePosition,
        parsed: GravityParsedDocument
    ) -> String? {
        guard let receiver = receiverPath.first else {
            return nil
        }
        let containingRegion = parsed.typeRegions.first { $0.symbol.range.contains(position) }
        var inferredType: String
        if receiver == "this", let containingRegion {
            inferredType = containingRegion.symbol.name
        } else {
            inferredType = containingRegion?.implicitTypes[receiver] ?? parsed.inferredTypes[receiver] ?? receiver
        }
        for memberName in receiverPath.dropFirst() {
            guard let returnType = GravityAPICatalog.member(named: memberName, in: inferredType)?.returnType else {
                return nil
            }
            inferredType = returnType
        }
        return inferredType
    }

    private static func receiverPath(beforeMemberAt memberIndex: Int, tokens: [GravityToken]) -> [String]? {
        guard memberIndex >= 2, tokens[memberIndex - 1].text == "." else {
            return nil
        }
        var result: [String] = []
        var cursor = memberIndex - 2
        while cursor >= 0, tokens[cursor].kind == .identifier {
            result.insert(tokens[cursor].text, at: 0)
            guard cursor >= 2, tokens[cursor - 1].text == "." else {
                break
            }
            cursor -= 2
        }
        return result.isEmpty ? nil : result
    }
}

private struct GravityCompletionContext {
    var prefix: String
    var receiverPath: [String]?
    var replacementRange: GravitySourceRange
    var isAnnotation = false

    init?(text: String, position: GravitySourcePosition) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.indices.contains(position.line) else {
            return nil
        }
        let line = String(lines[position.line])
        guard let caretIndex = line.stringIndex(atUTF16Offset: position.utf16Column) else {
            return nil
        }
        var prefixStart = caretIndex
        while prefixStart > line.startIndex {
            let previous = line.index(before: prefixStart)
            let character = line[previous]
            guard character == "_" || character.isLetter || character.isNumber else {
                break
            }
            prefixStart = previous
        }
        prefix = String(line[prefixStart..<caretIndex])
        let prefixStartColumn = line[..<prefixStart].utf16.count
        replacementRange = GravitySourceRange(
            start: GravitySourcePosition(line: position.line, utf16Column: prefixStartColumn),
            end: position
        )

        guard prefixStart > line.startIndex else {
            receiverPath = nil
            return
        }
        let dotIndex = line.index(before: prefixStart)
        if line[dotIndex] == "@" {
            isAnnotation = true
            receiverPath = nil
            return
        }
        guard line[dotIndex] == "." else {
            receiverPath = nil
            return
        }
        var expressionStart = dotIndex
        while expressionStart > line.startIndex {
            let previous = line.index(before: expressionStart)
            let character = line[previous]
            guard character == "_" || character == "." || character.isLetter || character.isNumber else {
                break
            }
            expressionStart = previous
        }
        let components = line[expressionStart..<dotIndex]
            .split(separator: ".")
            .map(String.init)
        receiverPath = components.isEmpty ? nil : components
    }
}

extension String {
    func stringIndex(atUTF16Offset offset: Int) -> String.Index? {
        guard
            offset >= 0,
            let utf16Index = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex)
        else {
            return nil
        }
        return Self.Index(utf16Index, within: self)
    }
}
