@preconcurrency import Foundation

struct EditorSourceLocation: Equatable, Hashable, Sendable {
    var line: Int
    var character: Int
}

struct EditorSourceRange: Equatable, Hashable, Sendable {
    var start: EditorSourceLocation
    var end: EditorSourceLocation
}

enum EditorDiagnosticSeverity: String, Equatable, Hashable, Sendable {
    case error
    case warning
    case information
    case hint
}

struct EditorDiagnostic: Equatable, Hashable, Sendable {
    var filePath: String
    var range: EditorSourceRange
    var severity: EditorDiagnosticSeverity
    var message: String
    var source: String

    var isLanguageServiceDiagnostic: Bool {
        source == "sourcekit-lsp" || source == "adascript-lsp"
    }

    static func diagnostics(from result: EditorProcessResult, projectURL: URL) -> [Self] {
        parseBuildOutput(result.standardOutput, projectURL: projectURL)
            + parseStandardError(result.standardError, command: result.command, projectURL: projectURL, failed: !result.succeeded)
    }

    static func parseBuildOutput(_ output: String, projectURL: URL) -> [Self] {
        output
            .components(separatedBy: .newlines)
            .compactMap { parseBuildDiagnosticLine($0, projectURL: projectURL) }
    }

    private static func parseStandardError(_ output: String, command: EditorProcessCommand, projectURL: URL, failed: Bool) -> [Self] {
        output
            .components(separatedBy: .newlines)
            .compactMap { line -> Self? in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else {
                    return nil
                }

                if let diagnostic = parseBuildDiagnosticLine(trimmedLine, projectURL: projectURL) {
                    return diagnostic
                }

                return Self(
                    filePath: projectURL.appendingPathComponent("Package.swift", isDirectory: false).path,
                    range: EditorSourceRange(
                        start: EditorSourceLocation(line: 0, character: 0),
                        end: EditorSourceLocation(line: 0, character: 1)
                    ),
                    severity: severity(forStandardErrorLine: trimmedLine, failed: failed),
                    message: trimmedLine,
                    source: command.displayName
                )
            }
    }

    private static func severity(forStandardErrorLine line: String, failed: Bool) -> EditorDiagnosticSeverity {
        let lowercasedLine = line.lowercased()
        if failed || lowercasedLine.contains("error:") {
            return .error
        }
        if lowercasedLine.contains("warning:") {
            return .warning
        }
        return .information
    }

    private static func parseBuildDiagnosticLine(_ line: String, projectURL: URL) -> Self? {
        let parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard
            parts.count == 5,
            let lineNumber = Int(parts[1]),
            let columnNumber = Int(parts[2])
        else {
            return nil
        }

        let severity: EditorDiagnosticSeverity =
            switch parts[3].trimmingCharacters(in: .whitespaces) {
            case "error":
                .error
            case "warning":
                .warning
            case "note":
                .information
            default:
                .hint
            }

        let rawPath = parts[0]
        let absolutePath = rawPath.hasPrefix("/") ? rawPath : projectURL.appendingPathComponent(rawPath).path
        let zeroBasedLine = max(0, lineNumber - 1)
        let zeroBasedColumn = max(0, columnNumber - 1)

        return Self(
            filePath: absolutePath,
            range: EditorSourceRange(
                start: EditorSourceLocation(line: zeroBasedLine, character: zeroBasedColumn),
                end: EditorSourceLocation(line: zeroBasedLine, character: zeroBasedColumn + 1)
            ),
            severity: severity,
            message: parts[4].trimmingCharacters(in: .whitespaces),
            source: "swift"
        )
    }
}

struct EditorSourceSymbolTarget: Equatable, Hashable, Sendable {
    var uri: String
    var filePath: String
    var range: EditorSourceRange
    var selectionRange: EditorSourceRange
    var content: String?
    var documentation: String?
}

struct EditorSourceReference: Equatable, Hashable, Sendable {
    var uri: String
    var filePath: String
    var range: EditorSourceRange
}

struct EditorSymbolHover: Equatable, Sendable {
    var contents: String
    var range: EditorSourceRange?
}

enum EditorDocumentHighlightKind: String, Equatable, Sendable {
    case text
    case read
    case write
}

struct EditorDocumentHighlight: Equatable, Sendable {
    var range: EditorSourceRange
    var kind: EditorDocumentHighlightKind
}

struct EditorSemanticToken: Equatable, Hashable, Sendable {
    var line: Int
    var startCharacter: Int
    var length: Int
    var type: String
    var modifiers: [String]
}

enum EditorCompletionKind: Equatable, Hashable, Sendable {
    case annotation
    case `class`
    case constant
    case constructor
    case color
    case `enum`
    case enumMember
    case event
    case field
    case file
    case folder
    case function
    case interface
    case keyword
    case method
    case module
    case `operator`
    case property
    case reference
    case snippet
    case `struct`
    case typeParameter
    case text
    case unit
    case value
    case variable
    case unknown

    init(lspValue: Int?, label: String, insertText: String? = nil) {
        if label.hasPrefix("@") || insertText?.hasPrefix("@") == true {
            self = .annotation
            return
        }

        self =
            switch lspValue {
            case 1: .text
            case 2: .method
            case 3: .function
            case 4: .constructor
            case 5: .field
            case 6: .variable
            case 7: .class
            case 8: .interface
            case 9: .module
            case 10: .property
            case 11: .unit
            case 12: .value
            case 13: .enum
            case 14: .keyword
            case 15: .snippet
            case 16: .color
            case 17: .file
            case 18: .reference
            case 19: .folder
            case 20: .enumMember
            case 21: .constant
            case 22: .struct
            case 23: .event
            case 24: .operator
            case 25: .typeParameter
            default: .unknown
            }
    }
}

struct EditorCompletionItem: Equatable, Hashable, Sendable {
    var label: String
    var detail: String?
    var insertText: String
    var replacementRange: EditorSourceRange?
    var sortText: String?
    var kind: EditorCompletionKind = .unknown
}

struct SourceKitLSPDocumentIdentifier: Equatable, Hashable, Sendable {
    var uri: String

    init(fileURL: URL) {
        self.uri = fileURL.absoluteURL.absoluteString
    }
}

extension EditorSourceLocation {
    var jsonRPCValue: JSONRPCValue {
        .object([
            "line": .int(line),
            "character": .int(character),
        ])
    }
}

protocol SourceKitLSPConnecting: Sendable {
    func start(executablePath: String, projectURL: URL) async throws
    func request(method: String, params: JSONRPCValue?) async throws -> JSONRPCValue?
    func notify(method: String, params: JSONRPCValue?) async throws
    func setNotificationHandler(_ handler: (@Sendable (String, JSONRPCValue?) async -> Void)?) async
    func stop() async
}

actor SourceKitLSPClient {
    private let connection: any SourceKitLSPConnecting
    private var nextVersionByURI: [String: Int] = [:]
    private var openedURIs: Set<String> = []
    private var preparedURIs: Set<String> = []
    private var documentTextByURI: [String: String] = [:]
    private(set) var diagnosticsByURI: [String: [EditorDiagnostic]] = [:]
    private(set) var semanticTokensByURI: [String: [EditorSemanticToken]] = [:]
    private var diagnosticsHandler: (@Sendable (String, [EditorDiagnostic]) async -> Void)?

    init(connection: any SourceKitLSPConnecting) {
        self.connection = connection
    }

    func start(toolchain: SwiftToolchain, projectURL: URL) async throws {
        guard let sourceKitLSPExecutablePath = toolchain.sourceKitLSPExecutablePath else {
            throw SourceKitLSPError.sourceKitLSPUnavailable
        }

        await connection.setNotificationHandler { [weak self] method, params in
            await self?.handleNotification(method: method, params: params)
        }
        try await connection.start(executablePath: sourceKitLSPExecutablePath, projectURL: projectURL)
        _ = try await connection.request(
            method: "initialize",
            params: .object([
                "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
                "rootUri": .string(projectURL.absoluteString),
                "workspaceFolders": .array([
                    .object([
                        "name": .string(projectURL.lastPathComponent),
                        "uri": .string(projectURL.absoluteString),
                    ])
                ]),
                "capabilities": .object([
                    "experimental": .object([
                        "sourcekit/workspace/getReferenceDocument": .object([
                            "supported": .bool(true)
                        ])
                    ]),
                    "workspace": .object([
                        "workspaceFolders": .bool(true)
                    ]),
                    "textDocument": .object([
                        "completion": .object([
                            "completionItem": .object([
                                "snippetSupport": .bool(false),
                                "insertReplaceSupport": .bool(false),
                            ])
                        ]),
                        "publishDiagnostics": .object([
                            "relatedInformation": .bool(true),
                            "versionSupport": .bool(true),
                        ]),
                        "semanticTokens": .object([
                            "dynamicRegistration": .bool(false),
                            "formats": .array([.string("relative")]),
                            "requests": .object([
                                "full": .bool(true),
                                "range": .bool(false),
                            ]),
                            "tokenTypes": .array(Self.semanticTokenTypes.map { .string($0) }),
                            "tokenModifiers": .array(Self.semanticTokenModifiers.map { .string($0) }),
                        ]),
                    ]),
                ]),
            ])
        )
        try await connection.notify(method: "initialized", params: .object([:]))
    }

    func setDiagnosticsHandler(_ handler: @Sendable @escaping (String, [EditorDiagnostic]) async -> Void) {
        diagnosticsHandler = handler
    }

    func openDocument(fileURL: URL, language: EditorSourceLanguage, text: String) async throws {
        let identifier = SourceKitLSPDocumentIdentifier(fileURL: fileURL)
        if openedURIs.contains(identifier.uri) {
            try await changeDocument(fileURL: fileURL, text: text)
            return
        }

        try await prepareDocument(fileURL: fileURL)
        if openedURIs.contains(identifier.uri) {
            try await changeDocument(fileURL: fileURL, text: text)
            return
        }
        nextVersionByURI[identifier.uri] = 1
        openedURIs.insert(identifier.uri)
        documentTextByURI[identifier.uri] = text

        try await connection.notify(
            method: "textDocument/didOpen",
            params: .object([
                "textDocument": .object([
                    "uri": .string(identifier.uri),
                    "languageId": .string(language.lspLanguageID),
                    "version": .int(1),
                    "text": .string(text),
                ])
            ])
        )
        _ = try await connection.request(method: "workspace/synchronize", params: .object([:]))
    }

    func changeDocument(fileURL: URL, text: String) async throws {
        let identifier = SourceKitLSPDocumentIdentifier(fileURL: fileURL)
        let version = (nextVersionByURI[identifier.uri] ?? 1) + 1
        nextVersionByURI[identifier.uri] = version
        documentTextByURI[identifier.uri] = text

        try await connection.notify(
            method: "textDocument/didChange",
            params: .object([
                "textDocument": .object([
                    "uri": .string(identifier.uri),
                    "version": .int(version),
                ]),
                "contentChanges": .array([
                    .object(["text": .string(text)])
                ]),
            ])
        )
    }

    func saveDocument(fileURL: URL) async throws {
        try await connection.notify(
            method: "textDocument/didSave",
            params: .object([
                "textDocument": .object([
                    "uri": .string(SourceKitLSPDocumentIdentifier(fileURL: fileURL).uri)
                ])
            ])
        )
    }

    func refreshSemanticTokens(fileURL: URL) async throws -> [EditorSemanticToken] {
        let uri = SourceKitLSPDocumentIdentifier(fileURL: fileURL).uri
        let response = try await connection.request(
            method: "textDocument/semanticTokens/full",
            params: .object([
                "textDocument": .object([
                    "uri": .string(uri)
                ])
            ])
        )
        var tokens = Self.decodeSemanticTokens(from: response, legend: Self.semanticTokenTypes, modifiersLegend: Self.semanticTokenModifiers)
        if let text = documentTextByURI[uri] {
            tokens = tokens.map { token in
                let editorRange = Self.editorRange(
                    fromLSPRange: EditorSourceRange(
                        start: EditorSourceLocation(line: token.line, character: token.startCharacter),
                        end: EditorSourceLocation(line: token.line, character: token.startCharacter + token.length)
                    ),
                    in: text
                )
                return EditorSemanticToken(
                    line: editorRange.start.line,
                    startCharacter: editorRange.start.character,
                    length: max(0, editorRange.end.character - editorRange.start.character),
                    type: token.type,
                    modifiers: token.modifiers
                )
            }
        }
        semanticTokensByURI[uri] = tokens
        return tokens
    }

    func completion(fileURL: URL, position: EditorSourceLocation) async throws -> [EditorCompletionItem] {
        let uri = SourceKitLSPDocumentIdentifier(fileURL: fileURL).uri
        let response = try await connection.request(
            method: "textDocument/completion",
            params: textDocumentPositionParams(fileURL: fileURL, position: position)
        )
        let items = Self.decodeCompletionItems(from: response)
        guard let text = documentTextByURI[uri] else {
            return items
        }
        return items.map { item in
            var item = item
            item.replacementRange = item.replacementRange.map { Self.editorRange(fromLSPRange: $0, in: text) }
            return item
        }
    }

    func definition(fileURL: URL, position: EditorSourceLocation) async throws -> [EditorSourceSymbolTarget] {
        let response = try await connection.request(
            method: "textDocument/definition",
            params: textDocumentPositionParams(fileURL: fileURL, position: position)
        )
        var targets = Self.decodeDefinitionTargets(from: response)
        for index in targets.indices where !Self.isFileURI(targets[index].uri) {
            guard let content = try? await referenceDocument(uri: targets[index].uri) else {
                continue
            }
            targets[index].content = content
            targets[index].range = Self.editorRange(fromLSPRange: targets[index].range, in: content)
            targets[index].selectionRange = Self.editorRange(fromLSPRange: targets[index].selectionRange, in: content)
        }
        return targets
    }

    private func referenceDocument(uri: String) async throws -> String? {
        let response = try await connection.request(
            method: "sourcekit/workspace/getReferenceDocument",
            params: .object(["uri": .string(uri)])
        )
        guard case let .object(object)? = response, case let .string(content)? = object["content"] else {
            return nil
        }
        return content
    }

    func references(fileURL: URL, position: EditorSourceLocation, includeDeclaration: Bool = true) async throws -> [EditorSourceReference] {
        guard case var .object(params) = textDocumentPositionParams(fileURL: fileURL, position: position) else {
            return []
        }
        params["context"] = .object(["includeDeclaration": .bool(includeDeclaration)])
        let response = try await connection.request(
            method: "textDocument/references",
            params: .object(params)
        )
        return Self.decodeReferences(from: response)
    }

    func hover(fileURL: URL, position: EditorSourceLocation) async throws -> EditorSymbolHover? {
        let response = try await connection.request(
            method: "textDocument/hover",
            params: textDocumentPositionParams(fileURL: fileURL, position: position)
        )
        guard var hover = Self.decodeHover(from: response) else {
            return nil
        }
        guard let range = hover.range else {
            return hover
        }

        let uri = SourceKitLSPDocumentIdentifier(fileURL: fileURL).uri
        if let text = documentTextByURI[uri] {
            hover.range = Self.editorRange(fromLSPRange: range, in: text)
        }
        return hover
    }

    func documentHighlights(fileURL: URL, position: EditorSourceLocation) async throws -> [EditorDocumentHighlight] {
        let uri = SourceKitLSPDocumentIdentifier(fileURL: fileURL).uri
        let response = try await connection.request(
            method: "textDocument/documentHighlight",
            params: textDocumentPositionParams(fileURL: fileURL, position: position)
        )
        let highlights = Self.decodeDocumentHighlights(from: response)
        guard let text = documentTextByURI[uri] else {
            return highlights
        }
        return highlights.map { highlight in
            EditorDocumentHighlight(range: Self.editorRange(fromLSPRange: highlight.range, in: text), kind: highlight.kind)
        }
    }

    func stop() async {
        await connection.setNotificationHandler(nil)
        await connection.stop()
    }

    private func prepareDocument(fileURL: URL) async throws {
        let uri = SourceKitLSPDocumentIdentifier(fileURL: fileURL).uri
        guard !preparedURIs.contains(uri) else {
            return
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline {
            let response = try await connection.request(
                method: "workspace/_sourceKitOptions",
                params: .object([
                    "textDocument": .object(["uri": .string(uri)]),
                    "prepareTarget": .bool(true),
                    "allowFallbackSettings": .bool(false),
                ])
            )
            if case let .object(options)? = response,
                options["kind"]?.stringValue == "normal" {
                preparedURIs.insert(uri)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw SourceKitLSPError.buildSettingsUnavailable(fileURL.path)
    }

    private func handleNotification(method: String, params: JSONRPCValue?) async {
        guard
            method == "textDocument/publishDiagnostics",
            let published = Self.decodePublishedDiagnostics(from: params)
        else {
            return
        }

        let diagnostics: [EditorDiagnostic]
        if let text = documentTextByURI[published.uri] {
            diagnostics = published.diagnostics.map { diagnostic in
                var diagnostic = diagnostic
                diagnostic.range = Self.editorRange(fromLSPRange: diagnostic.range, in: text)
                return diagnostic
            }
        } else {
            diagnostics = published.diagnostics
        }
        diagnosticsByURI[published.uri] = diagnostics
        await diagnosticsHandler?(published.uri, diagnostics)
    }

    private func textDocumentPositionParams(fileURL: URL, position: EditorSourceLocation) -> JSONRPCValue {
        let uri = SourceKitLSPDocumentIdentifier(fileURL: fileURL).uri
        let lspPosition = documentTextByURI[uri].map { Self.lspLocation(fromEditorLocation: position, in: $0) } ?? position
        return .object([
            "textDocument": .object([
                "uri": .string(uri)
            ]),
            "position": lspPosition.jsonRPCValue,
        ])
    }

    static func lspLocation(fromEditorLocation location: EditorSourceLocation, in text: String) -> EditorSourceLocation {
        let lines = text.components(separatedBy: .newlines)
        guard lines.indices.contains(location.line) else {
            return location
        }
        let line = lines[location.line]
        let characterColumn = min(max(0, location.character), line.count)
        let index = line.index(line.startIndex, offsetBy: characterColumn)
        return EditorSourceLocation(line: location.line, character: line[..<index].utf16.count)
    }

    static func editorRange(fromLSPRange range: EditorSourceRange, in text: String) -> EditorSourceRange {
        EditorSourceRange(
            start: editorLocation(fromLSPLocation: range.start, in: text),
            end: editorLocation(fromLSPLocation: range.end, in: text)
        )
    }

    private static func editorLocation(fromLSPLocation location: EditorSourceLocation, in text: String) -> EditorSourceLocation {
        let lines = text.components(separatedBy: .newlines)
        guard lines.indices.contains(location.line) else {
            return location
        }

        var utf16Offset = 0
        var characterOffset = 0
        for character in lines[location.line] {
            let characterLength = String(character).utf16.count
            guard utf16Offset + characterLength <= location.character else {
                break
            }
            utf16Offset += characterLength
            characterOffset += 1
        }
        return EditorSourceLocation(line: location.line, character: characterOffset)
    }

    static func decodeSemanticTokens(from response: JSONRPCValue?, legend: [String], modifiersLegend: [String]) -> [EditorSemanticToken] {
        guard
            case let .object(object)? = response,
            case let .array(values)? = object["data"]
        else {
            return []
        }

        let numbers = values.compactMap(\.intValue)
        guard numbers.count % 5 == 0 else {
            return []
        }

        var tokens: [EditorSemanticToken] = []
        var line = 0
        var character = 0

        for index in stride(from: 0, to: numbers.count, by: 5) {
            let deltaLine = numbers[index]
            let deltaStart = numbers[index + 1]
            let length = numbers[index + 2]
            let typeIndex = numbers[index + 3]
            let modifiersMask = numbers[index + 4]

            line += deltaLine
            character = deltaLine == 0 ? character + deltaStart : deltaStart

            let type = legend.indices.contains(typeIndex) ? legend[typeIndex] : "unknown"
            let modifiers = modifiersLegend.enumerated()
                .compactMap { offset, modifier in
                    (modifiersMask & (1 << offset)) == 0 ? nil : modifier
                }

            tokens.append(
                EditorSemanticToken(
                    line: line,
                    startCharacter: character,
                    length: length,
                    type: type,
                    modifiers: modifiers
                )
            )
        }

        return tokens
    }

    static func decodeCompletionItems(from response: JSONRPCValue?) -> [EditorCompletionItem] {
        let values: [JSONRPCValue]
        switch response {
        case let .array(items):
            values = items
        case let .object(object):
            guard case let .array(items)? = object["items"] else {
                return []
            }
            values = items
        default:
            return []
        }

        return
            values.compactMap { value in
                guard
                    case let .object(object) = value,
                    case let .string(label)? = object["label"]
                else {
                    return nil
                }

                let textEdit: (newText: String, range: EditorSourceRange)? = {
                    guard
                        case let .object(edit)? = object["textEdit"],
                        case let .string(newText)? = edit["newText"],
                        let rangeValue = edit["range"],
                        let range = decodeRange(rangeValue)
                    else {
                        return nil
                    }
                    return (newText, range)
                }()
                let insertText: String
                if let textEdit {
                    insertText = textEdit.newText
                } else if case let .string(value)? = object["insertText"] {
                    insertText = value
                } else {
                    insertText = label
                }

                return EditorCompletionItem(
                    label: label,
                    detail: object["detail"]?.stringValue,
                    insertText: insertText,
                    replacementRange: textEdit?.range,
                    sortText: object["sortText"]?.stringValue,
                    kind: EditorCompletionKind(lspValue: object["kind"]?.intValue, label: label, insertText: insertText)
                )
            }
            .sorted { lhs, rhs in
                (lhs.sortText ?? lhs.label).localizedStandardCompare(rhs.sortText ?? rhs.label) == .orderedAscending
            }
    }

    static func decodePublishedDiagnostics(from params: JSONRPCValue?) -> (uri: String, diagnostics: [EditorDiagnostic])? {
        guard
            case let .object(object)? = params,
            case let .string(uri)? = object["uri"],
            case let .array(values)? = object["diagnostics"]
        else {
            return nil
        }

        let filePath = filePath(fromURI: uri)
        let diagnostics = values.compactMap { value -> EditorDiagnostic? in
            guard
                case let .object(diagnostic) = value,
                let rangeValue = diagnostic["range"],
                let range = decodeRange(rangeValue),
                case let .string(message)? = diagnostic["message"]
            else {
                return nil
            }

            let severity: EditorDiagnosticSeverity =
                switch diagnostic["severity"]?.intValue {
                case 1:
                    .error
                case 2:
                    .warning
                case 3:
                    .information
                default:
                    .hint
                }
            return EditorDiagnostic(
                filePath: filePath,
                range: range,
                severity: severity,
                message: message,
                source: "sourcekit-lsp"
            )
        }
        return (uri, diagnostics)
    }

    static func decodeDefinitionTargets(from response: JSONRPCValue?) -> [EditorSourceSymbolTarget] {
        switch response {
        case let .object(object):
            if let target = decodeLocationLink(object)
                ?? decodeLocation(object)
                .map({ location in
                    EditorSourceSymbolTarget(uri: location.uri, filePath: location.filePath, range: location.range, selectionRange: location.range)
                }) {
                return [target]
            }
            return []
        case let .array(values):
            return values.flatMap { value -> [EditorSourceSymbolTarget] in
                guard case let .object(object) = value else {
                    return []
                }
                if let link = decodeLocationLink(object) {
                    return [link]
                }
                if let location = decodeLocation(object) {
                    return [
                        EditorSourceSymbolTarget(
                            uri: location.uri,
                            filePath: location.filePath,
                            range: location.range,
                            selectionRange: location.range
                        )
                    ]
                }
                return []
            }
        default:
            return []
        }
    }

    static func decodeReferences(from response: JSONRPCValue?) -> [EditorSourceReference] {
        guard case let .array(values)? = response else {
            return []
        }

        return values.compactMap { value in
            guard
                case let .object(object) = value,
                let location = decodeLocation(object)
            else {
                return nil
            }

            return EditorSourceReference(uri: location.uri, filePath: location.filePath, range: location.range)
        }
    }

    static func decodeHover(from response: JSONRPCValue?) -> EditorSymbolHover? {
        guard
            case let .object(object)? = response,
            let contents = object["contents"],
            let text = decodeMarkupContent(contents)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return nil
        }

        return EditorSymbolHover(contents: text, range: object["range"].flatMap(decodeRange))
    }

    static func decodeDocumentHighlights(from response: JSONRPCValue?) -> [EditorDocumentHighlight] {
        guard case let .array(values)? = response else {
            return []
        }

        return values.compactMap { value in
            guard
                case let .object(object) = value,
                let rangeValue = object["range"],
                let range = decodeRange(rangeValue)
            else {
                return nil
            }

            let kind: EditorDocumentHighlightKind =
                switch object["kind"]?.intValue {
                case 2:
                    .read
                case 3:
                    .write
                default:
                    .text
                }

            return EditorDocumentHighlight(range: range, kind: kind)
        }
    }

    private static func decodeLocation(_ object: [String: JSONRPCValue]) -> (uri: String, filePath: String, range: EditorSourceRange)? {
        guard
            case let .string(uri)? = object["uri"],
            let rangeValue = object["range"],
            let range = decodeRange(rangeValue)
        else {
            return nil
        }

        return (uri, filePath(fromURI: uri), range)
    }

    private static func decodeLocationLink(_ object: [String: JSONRPCValue]) -> EditorSourceSymbolTarget? {
        guard
            case let .string(uri)? = object["targetUri"],
            let targetRangeValue = object["targetRange"],
            let targetSelectionRangeValue = object["targetSelectionRange"],
            let targetRange = decodeRange(targetRangeValue),
            let targetSelectionRange = decodeRange(targetSelectionRangeValue)
        else {
            return nil
        }

        return EditorSourceSymbolTarget(
            uri: uri,
            filePath: filePath(fromURI: uri),
            range: targetRange,
            selectionRange: targetSelectionRange
        )
    }

    private static func decodeRange(_ value: JSONRPCValue) -> EditorSourceRange? {
        guard
            case let .object(object) = value,
            let startValue = object["start"],
            let endValue = object["end"],
            let start = decodePosition(startValue),
            let end = decodePosition(endValue)
        else {
            return nil
        }

        return EditorSourceRange(start: start, end: end)
    }

    private static func decodePosition(_ value: JSONRPCValue) -> EditorSourceLocation? {
        guard
            case let .object(object) = value,
            let line = object["line"]?.intValue,
            let character = object["character"]?.intValue
        else {
            return nil
        }

        return EditorSourceLocation(line: line, character: character)
    }

    private static func decodeMarkupContent(_ value: JSONRPCValue) -> String? {
        switch value {
        case let .string(string):
            return string
        case let .object(object):
            if case let .string(value)? = object["value"] {
                return value
            }
            return nil
        case let .array(values):
            let parts = values.compactMap(decodeMarkupContent)
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        default:
            return nil
        }
    }

    private static func filePath(fromURI uri: String) -> String {
        guard let url = URL(string: uri) else {
            return uri
        }

        return url.path.removingPercentEncoding ?? url.path
    }

    private static func isFileURI(_ uri: String) -> Bool {
        URL(string: uri)?.scheme?.lowercased() == "file"
    }

    private static let semanticTokenTypes = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter",
        "variable", "property", "enumMember", "event", "function", "method", "macro", "keyword",
        "modifier", "comment", "string", "number", "regexp", "operator", "decorator",
    ]

    private static let semanticTokenModifiers = [
        "declaration", "definition", "readonly", "static", "deprecated", "abstract", "async",
        "modification", "documentation", "defaultLibrary",
    ]
}

enum SourceKitLSPError: Error, Equatable, Sendable {
    case sourceKitLSPUnavailable
    case connectionClosed
    case invalidResponse
    case serverError(code: Int?, message: String)
    case buildSettingsUnavailable(String)
}

#if os(macOS) || os(Linux) || os(Windows)
    actor SourceKitLSPStdioConnection: SourceKitLSPConnecting {
        nonisolated static let launchArguments = ["--experimental-feature", "sourcekit-options-request"]

        enum IncomingMessageRoute: Equatable {
            case serverMessage(method: String, id: JSONRPCValue?)
            case response(id: Int)
            case invalid
        }

        private var process: Process?
        private var input: Pipe?
        private var output: Pipe?
        private var nextRequestID = 1
        private var pendingResponses: [Int: CheckedContinuation<JSONRPCValue?, any Error>] = [:]
        private var readBuffer = Data()
        private var notificationHandler: (@Sendable (String, JSONRPCValue?) async -> Void)?

        func start(executablePath: String, projectURL: URL) async throws {
            let process = Process()
            let input = Pipe()
            let output = Pipe()

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = Self.launchArguments
            process.currentDirectoryURL = projectURL
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.standardError

            try process.run()

            self.process = process
            self.input = input
            self.output = output
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                Task {
                    await self?.receive(data)
                }
            }
            process.terminationHandler = { [weak self] _ in
                Task {
                    await self?.connectionDidClose()
                }
            }
        }

        func request(method: String, params: JSONRPCValue?) async throws -> JSONRPCValue? {
            let requestID = nextRequestID
            nextRequestID += 1
            return try await withCheckedThrowingContinuation { continuation in
                pendingResponses[requestID] = continuation
                do {
                    try write(
                        .object([
                            "jsonrpc": .string("2.0"),
                            "id": .int(requestID),
                            "method": .string(method),
                            "params": params ?? .null,
                        ])
                    )
                } catch {
                    pendingResponses[requestID] = nil
                    continuation.resume(throwing: error)
                }
            }
        }

        func notify(method: String, params: JSONRPCValue?) async throws {
            try write(
                .object([
                    "jsonrpc": .string("2.0"),
                    "method": .string(method),
                    "params": params ?? .null,
                ])
            )
        }

        func setNotificationHandler(_ handler: (@Sendable (String, JSONRPCValue?) async -> Void)?) {
            notificationHandler = handler
        }

        func stop() {
            output?.fileHandleForReading.readabilityHandler = nil
            process?.terminate()
            process = nil
            input = nil
            output = nil
            readBuffer.removeAll(keepingCapacity: false)
            let responses = pendingResponses.values
            pendingResponses.removeAll()
            for response in responses {
                response.resume(throwing: SourceKitLSPError.connectionClosed)
            }
        }

        private func write(_ value: JSONRPCValue) throws {
            guard let input else {
                throw SourceKitLSPError.connectionClosed
            }

            let data = try JSONEncoder().encode(value)
            var message = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
            message.append(data)
            input.fileHandleForWriting.write(message)
        }

        private func receive(_ data: Data) async {
            guard !data.isEmpty else {
                connectionDidClose()
                return
            }

            readBuffer.append(data)
            let separator = Data("\r\n\r\n".utf8)
            while let headerRange = readBuffer.range(of: separator) {
                let header = readBuffer[..<headerRange.lowerBound]
                guard
                    let headerString = String(bytes: header, encoding: .utf8),
                    let contentLengthLine = headerString.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                    let length = Int(contentLengthLine.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "")
                else {
                    failPendingResponses(with: .invalidResponse)
                    readBuffer.removeAll()
                    return
                }

                let bodyStart = headerRange.upperBound
                guard readBuffer.count >= bodyStart + length else {
                    return
                }
                let body = readBuffer[bodyStart..<(bodyStart + length)]
                readBuffer.removeSubrange(..<(bodyStart + length))

                do {
                    let message = try JSONDecoder().decode(JSONRPCValue.self, from: body)
                    await handle(message)
                } catch {
                    failPendingResponses(with: .invalidResponse)
                }
            }
        }

        private func handle(_ message: JSONRPCValue) async {
            guard case let .object(object) = message else {
                return
            }

            switch Self.route(for: object) {
            case let .serverMessage(method, requestID):
                if let requestID {
                    try? write(
                        .object([
                            "jsonrpc": .string("2.0"),
                            "id": requestID,
                            "result": serverRequestResult(method: method, params: object["params"]),
                        ])
                    )
                } else {
                    await notificationHandler?(method, object["params"])
                }
            case let .response(requestID):
                guard let response = pendingResponses.removeValue(forKey: requestID) else {
                    return
                }
                if case let .object(error)? = object["error"] {
                    response.resume(
                        throwing: SourceKitLSPError.serverError(
                            code: error["code"]?.intValue,
                            message: error["message"]?.stringValue ?? "Unknown SourceKit-LSP server error"
                        )
                    )
                } else {
                    response.resume(returning: object["result"])
                }
            case .invalid:
                return
            }
        }

        nonisolated static func route(for object: [String: JSONRPCValue]) -> IncomingMessageRoute {
            if case let .string(method)? = object["method"] {
                return .serverMessage(method: method, id: object["id"])
            }
            if let requestID = object["id"]?.intValue {
                return .response(id: requestID)
            }
            return .invalid
        }

        private func serverRequestResult(method: String, params: JSONRPCValue?) -> JSONRPCValue {
            if method == "workspace/configuration",
                case let .object(object)? = params,
                case let .array(items)? = object["items"] {
                return .array(items.map { _ in .null })
            }
            if method == "workspace/workspaceFolders" {
                return .array([])
            }
            return .null
        }

        private func connectionDidClose() {
            guard process != nil || !pendingResponses.isEmpty else {
                return
            }
            output?.fileHandleForReading.readabilityHandler = nil
            process = nil
            input = nil
            output = nil
            failPendingResponses(with: .connectionClosed)
        }

        private func failPendingResponses(with error: SourceKitLSPError) {
            let responses = pendingResponses.values
            pendingResponses.removeAll()
            for response in responses {
                response.resume(throwing: error)
            }
        }
    }
#else
    actor SourceKitLSPStdioConnection: SourceKitLSPConnecting {
        nonisolated static let launchArguments = ["--experimental-feature", "sourcekit-options-request"]

        enum IncomingMessageRoute: Equatable {
            case serverMessage(method: String, id: JSONRPCValue?)
            case response(id: Int)
            case invalid
        }

        func start(executablePath _: String, projectURL _: URL) async throws {
            throw SourceKitLSPError.sourceKitLSPUnavailable
        }

        func request(method _: String, params _: JSONRPCValue?) async throws -> JSONRPCValue? {
            throw SourceKitLSPError.sourceKitLSPUnavailable
        }

        func notify(method _: String, params _: JSONRPCValue?) async throws {
            throw SourceKitLSPError.sourceKitLSPUnavailable
        }

        func setNotificationHandler(_: (@Sendable (String, JSONRPCValue?) async -> Void)?) {}

        func stop() {}

        nonisolated static func route(for object: [String: JSONRPCValue]) -> IncomingMessageRoute {
            if case let .string(method)? = object["method"] {
                return .serverMessage(method: method, id: object["id"])
            }
            if let requestID = object["id"]?.intValue {
                return .response(id: requestID)
            }
            return .invalid
        }
    }
#endif

enum JSONRPCValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([Self])
    case object([String: Self])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: Self].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var intValue: Int? {
        switch self {
        case let .int(value):
            value
        case let .double(value):
            Int(value)
        default:
            nil
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }
}

extension EditorSourceLanguage {
    var lspLanguageID: String {
        switch self {
        case .c:
            "c"
        case .cpp:
            "cpp"
        case .swift,
            .packageManifest:
            "swift"
        default:
            rawValue
        }
    }
}
