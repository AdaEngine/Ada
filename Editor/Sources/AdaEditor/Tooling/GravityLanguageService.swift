import AdaEngine
import Foundation
import GravityLanguageCore

struct EditorGravityLanguageService: Sendable {
    private static let annotationLabels: Set<String> = [
        "access", "component", "environment", "export", "previewable", "query", "res",
        "resource", "scriptable", "state", "system", "tool", "view",
    ]

    static func completions(
        text: String,
        position: EditorSourceLocation
    ) -> [EditorCompletionItem] {
        let lspPosition = lspPosition(from: position, in: text)
        return completionItems(
            languageService().completions(text: text, position: lspPosition),
            text: text
        )
    }

    static func semanticTokens(text: String) -> [EditorSemanticToken] {
        languageService().semanticTokens(text: text)
            .compactMap { token in
                guard token.range.start.line == token.range.end.line else {
                    return nil
                }
                let start = editorPosition(from: token.range.start, in: text)
                let end = editorPosition(from: token.range.end, in: text)
                return EditorSemanticToken(
                    line: start.line,
                    startCharacter: start.character,
                    length: max(0, end.character - start.character),
                    type: token.kind.rawValue,
                    modifiers: []
                )
            }
    }

    static func hover(text: String, position: EditorSourceLocation) -> EditorSymbolHover? {
        guard
            let hover = languageService().hover(
                text: text,
                position: lspPosition(from: position, in: text)
            )
        else {
            return nil
        }
        return EditorSymbolHover(
            contents: hover.contents,
            range: editorRange(from: hover.range, in: text)
        )
    }

    static func definition(
        workspace: GravityWorkspace,
        uri: String,
        text: String,
        position: EditorSourceLocation
    ) -> EditorSourceSymbolTarget? {
        workspace.change(uri: uri, text: text, version: nil)
        guard
            let definition = workspace.definition(
                uri: uri,
                position: lspPosition(from: position, in: text)
            )
        else {
            return nil
        }
        let targetText = workspace.text(for: definition.uri) ?? ""
        let fileURL = URL(string: definition.uri)
        return EditorSourceSymbolTarget(
            uri: definition.uri,
            filePath: fileURL?.path.removingPercentEncoding ?? fileURL?.path ?? definition.uri,
            range: editorRange(from: definition.range, in: targetText),
            selectionRange: editorRange(from: definition.selectionRange, in: targetText)
        )
    }

    static func hover(
        workspace: GravityWorkspace,
        uri: String,
        text: String,
        position: EditorSourceLocation
    ) -> EditorSymbolHover? {
        workspace.setHostConstructors(hostConstructors())
        workspace.change(uri: uri, text: text, version: nil)
        guard let hover = workspace.hover(uri: uri, position: lspPosition(from: position, in: text)) else {
            return nil
        }
        return EditorSymbolHover(contents: hover.contents, range: editorRange(from: hover.range, in: text))
    }

    static func diagnostics(workspace: GravityWorkspace, fileURL: URL, text: String) -> [EditorDiagnostic] {
        workspace.setHostConstructors(hostConstructors())
        let uri = fileURL.standardizedFileURL.absoluteString
        workspace.change(uri: uri, text: text, version: nil)
        return (workspace.analysis(for: uri)?.diagnostics ?? [])
            .map { diagnostic in
                EditorDiagnostic(
                    filePath: fileURL.standardizedFileURL.path,
                    range: editorRange(from: diagnostic.range, in: text),
                    severity: diagnostic.severity == .error ? .error : .warning,
                    message: diagnostic.message,
                    source: "adascript-lsp"
                )
            }
    }

    static func completions(
        workspace: GravityWorkspace,
        uri: String,
        text: String,
        position: EditorSourceLocation
    ) -> [EditorCompletionItem] {
        workspace.setHostConstructors(hostConstructors())
        workspace.change(uri: uri, text: text, version: nil)
        return completionItems(
            workspace.completions(uri: uri, position: lspPosition(from: position, in: text)),
            text: text
        )
    }

    private static func hostConstructors() -> [GravityHostConstructor] {
        return RuntimeTypeRegistry.registeredRuntimeComponentConstructors().map { constructor in
            GravityHostConstructor(
                name: constructor.name,
                parameters: constructor.parameters.map(\.name)
            )
        }
    }

    private static func languageService() -> GravityLanguageService {
        GravityLanguageService(hostConstructors: hostConstructors())
    }

    private static func completionItems(
        _ completions: [GravityCompletion],
        text: String
    ) -> [EditorCompletionItem] {
        completions.map { completion in
            EditorCompletionItem(
                label: completion.label,
                detail: completion.detail,
                insertText: completion.insertText,
                replacementRange: editorRange(from: completion.replacementRange, in: text),
                sortText: completion.sortText,
                kind: completionKind(for: completion)
            )
        }
    }

    private static func completionKind(for completion: GravityCompletion) -> EditorCompletionKind {
        if annotationLabels.contains(completion.label) {
            return .annotation
        }

        return switch completion.kind {
        case .class: .class
        case .enum: .enum
        case .function: .function
        case .keyword: .keyword
        case .method: .method
        case .property: .property
        case .snippet: .snippet
        case .struct: .struct
        case .variable: .variable
        }
    }

    private static func lspPosition(from position: EditorSourceLocation, in text: String) -> GravitySourcePosition {
        let lines = text.components(separatedBy: .newlines)
        guard lines.indices.contains(position.line) else {
            return GravitySourcePosition(line: position.line, utf16Column: position.character)
        }
        let line = lines[position.line]
        let characterColumn = min(max(0, position.character), line.count)
        let index = line.index(line.startIndex, offsetBy: characterColumn)
        return GravitySourcePosition(line: position.line, utf16Column: line[..<index].utf16.count)
    }

    private static func editorRange(from range: GravitySourceRange, in text: String) -> EditorSourceRange {
        EditorSourceRange(
            start: editorPosition(from: range.start, in: text),
            end: editorPosition(from: range.end, in: text)
        )
    }

    private static func editorPosition(from position: GravitySourcePosition, in text: String) -> EditorSourceLocation {
        let lines = text.components(separatedBy: .newlines)
        guard lines.indices.contains(position.line) else {
            return EditorSourceLocation(line: position.line, character: position.utf16Column)
        }
        var utf16Offset = 0
        var characterOffset = 0
        for character in lines[position.line] {
            let characterLength = String(character).utf16.count
            guard utf16Offset + characterLength <= position.utf16Column else {
                break
            }
            utf16Offset += characterLength
            characterOffset += 1
        }
        return EditorSourceLocation(line: position.line, character: characterOffset)
    }
}
