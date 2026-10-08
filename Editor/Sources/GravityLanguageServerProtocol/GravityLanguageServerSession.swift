import Foundation
import GravityLanguageCore

public struct GravityLanguageServerAction {
    public var exitCode: Int32?
    public var outgoingMessages: [[String: Any]]

    public init(exitCode: Int32? = nil, outgoingMessages: [[String: Any]] = []) {
        self.exitCode = exitCode
        self.outgoingMessages = outgoingMessages
    }
}

public final class GravityLanguageServerSession {
    private let workspace: GravityWorkspace
    private var isInitialized = false
    private var isShutdown = false

    public init(workspace: GravityWorkspace = GravityWorkspace()) {
        self.workspace = workspace
    }

    // A protocol method router naturally has one branch per supported LSP method.
    public func handle(_ message: [String: Any]) -> GravityLanguageServerAction {
        guard let method = message["method"] as? String else {
            return GravityLanguageServerAction(outgoingMessages: [errorResponse(id: message["id"], code: -32600, message: "Invalid Request")])
        }
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        if !isInitialized, method != "initialize", method != "exit" {
            guard id != nil else {
                return GravityLanguageServerAction()
            }
            return GravityLanguageServerAction(outgoingMessages: [errorResponse(id: id, code: -32002, message: "Server not initialized")])
        }
        if isShutdown, method != "exit" {
            guard id != nil else {
                return GravityLanguageServerAction()
            }
            return GravityLanguageServerAction(outgoingMessages: [errorResponse(id: id, code: -32600, message: "Server has shut down")])
        }

        switch method {
        case "initialize":
            return initialize(id: id, params: params)
        case "initialized",
            "$/cancelRequest":
            return GravityLanguageServerAction()
        case "shutdown":
            isShutdown = true
            return GravityLanguageServerAction(outgoingMessages: id.map { [response(id: $0, result: NSNull())] } ?? [])
        case "exit":
            return GravityLanguageServerAction(exitCode: isShutdown ? 0 : 1)
        case "textDocument/didOpen":
            return didOpen(params: params)
        case "textDocument/didChange":
            return didChange(params: params)
        case "textDocument/didClose":
            return didClose(params: params)
        case "textDocument/didSave":
            return didSave(params: params)
        case "textDocument/completion":
            return completion(id: id, params: params)
        case "textDocument/definition":
            return definition(id: id, params: params)
        case "textDocument/codeAction":
            return codeAction(id: id, params: params)
        case "textDocument/hover",
            "textDocument/signatureHelp",
            "textDocument/semanticTokens/full":
            return languageFeature(method: method, id: id, params: params)
        case "textDocument/documentSymbol":
            return documentSymbols(id: id, params: params)
        case "workspace/didChangeWatchedFiles":
            return didChangeWatchedFiles(params: params)
        default:
            return methodNotFound(method, id: id)
        }
    }

    private func initialize(id: Any?, params: [String: Any]) -> GravityLanguageServerAction {
        guard !isInitialized, let id else {
            return GravityLanguageServerAction(outgoingMessages: [errorResponse(id: id, code: -32600, message: "Initialize may only be sent once")])
        }
        var rootURIs: [String] = []
        if let workspaceFolders = params["workspaceFolders"] as? [[String: Any]] {
            rootURIs += workspaceFolders.compactMap { $0["uri"] as? String }
        }
        if rootURIs.isEmpty, let rootURI = params["rootUri"] as? String {
            rootURIs.append(rootURI)
        }
        if let options = params["initializationOptions"] as? [String: Any],
            let constructorValues = options["hostConstructors"] as? [[String: Any]] {
            workspace.setHostConstructors(
                constructorValues.compactMap { value in
                    guard let name = value["name"] as? String,
                        let parameters = value["parameters"] as? [String] else {
                        return nil
                    }
                    return GravityHostConstructor(name: name, parameters: parameters)
                }
            )
        }
        workspace.configure(rootURIs: rootURIs)
        isInitialized = true

        let capabilities: [String: Any] = [
            "codeActionProvider": true,
            "completionProvider": [
                "resolveProvider": false,
                "triggerCharacters": ["."],
            ],
            "documentSymbolProvider": true,
            "definitionProvider": true,
            "hoverProvider": true,
            "positionEncoding": "utf-16",
            "semanticTokensProvider": [
                "full": true,
                "legend": [
                    "tokenModifiers": [],
                    "tokenTypes": GravitySemanticTokenKind.allCases.map(\.rawValue),
                ],
            ],
            "signatureHelpProvider": ["triggerCharacters": ["(", ","]],
            "textDocumentSync": [
                "change": 1,
                "openClose": true,
                "save": ["includeText": true],
            ],
        ]
        return GravityLanguageServerAction(outgoingMessages: [
            response(
                id: id,
                result: [
                    "capabilities": capabilities,
                    "serverInfo": ["name": "AdaEngine AdaScript Language Server", "version": "0.1.0"],
                ]
            )
        ])
    }

    private func didOpen(params: [String: Any]) -> GravityLanguageServerAction {
        guard
            let document = params["textDocument"] as? [String: Any],
            let uri = document["uri"] as? String,
            let text = document["text"] as? String
        else {
            return GravityLanguageServerAction()
        }
        workspace.open(uri: uri, text: text, version: document["version"] as? Int)
        return publishDiagnostics(uri: uri)
    }

    private func didChange(params: [String: Any]) -> GravityLanguageServerAction {
        guard
            let document = params["textDocument"] as? [String: Any],
            let uri = document["uri"] as? String,
            let changes = params["contentChanges"] as? [[String: Any]],
            let text = changes.last?["text"] as? String
        else {
            return GravityLanguageServerAction()
        }
        workspace.change(uri: uri, text: text, version: document["version"] as? Int)
        return publishDiagnostics(uri: uri)
    }

    private func didClose(params: [String: Any]) -> GravityLanguageServerAction {
        guard let document = params["textDocument"] as? [String: Any], let uri = document["uri"] as? String else {
            return GravityLanguageServerAction()
        }
        workspace.close(uri: uri)
        return GravityLanguageServerAction(outgoingMessages: [
            notification(
                method: "textDocument/publishDiagnostics",
                params: [
                    "diagnostics": [],
                    "uri": uri,
                ]
            )
        ])
    }

    private func didSave(params: [String: Any]) -> GravityLanguageServerAction {
        guard let document = params["textDocument"] as? [String: Any], let uri = document["uri"] as? String else {
            return GravityLanguageServerAction()
        }
        workspace.save(uri: uri, text: params["text"] as? String)
        return publishDiagnostics(uri: uri)
    }

    private func completion(id: Any?, params: [String: Any]) -> GravityLanguageServerAction {
        guard
            let id,
            let document = params["textDocument"] as? [String: Any],
            let uri = document["uri"] as? String,
            let position = Self.position(from: params["position"])
        else {
            return GravityLanguageServerAction(outgoingMessages: id.map { [errorResponse(id: $0, code: -32602, message: "Invalid completion parameters")] } ?? [])
        }
        let items = workspace.completions(uri: uri, position: position).map(Self.completionItem(from:))
        return GravityLanguageServerAction(outgoingMessages: [
            response(
                id: id,
                result: [
                    "isIncomplete": false,
                    "items": items,
                ]
            )
        ])
    }

    private func documentSymbols(id: Any?, params: [String: Any]) -> GravityLanguageServerAction {
        guard
            let id,
            let document = params["textDocument"] as? [String: Any],
            let uri = document["uri"] as? String
        else {
            return GravityLanguageServerAction(outgoingMessages: id.map { [errorResponse(id: $0, code: -32602, message: "Invalid document symbol parameters")] } ?? [])
        }
        let symbols = workspace.analysis(for: uri)?.symbols.map(Self.documentSymbol(from:)) ?? []
        return GravityLanguageServerAction(outgoingMessages: [response(id: id, result: symbols)])
    }

    private func definition(id: Any?, params: [String: Any]) -> GravityLanguageServerAction {
        guard
            let id,
            let document = params["textDocument"] as? [String: Any],
            let uri = document["uri"] as? String,
            let position = Self.position(from: params["position"])
        else {
            return GravityLanguageServerAction(outgoingMessages: id.map { [errorResponse(id: $0, code: -32602, message: "Invalid definition parameters")] } ?? [])
        }
        let result: Any = workspace.definition(uri: uri, position: position).map(Self.locationLink(from:)) ?? NSNull()
        return GravityLanguageServerAction(outgoingMessages: [response(id: id, result: result)])
    }

    private func codeAction(id: Any?, params: [String: Any]) -> GravityLanguageServerAction {
        guard
            let id,
            let document = params["textDocument"] as? [String: Any],
            let uri = document["uri"] as? String,
            let requestedRange = params["range"] as? [String: Any],
            let start = Self.position(from: requestedRange["start"]),
            let end = Self.position(from: requestedRange["end"])
        else {
            return GravityLanguageServerAction(outgoingMessages: id.map { [errorResponse(id: $0, code: -32602, message: "Invalid code action parameters")] } ?? [])
        }
        guard let text = workspace.text(for: uri) else {
            return GravityLanguageServerAction(outgoingMessages: [response(id: id, result: [])])
        }
        let fixes = GravityLanguageService().quickFixes(
            text: text,
            range: GravitySourceRange(start: start, end: end)
        )
        let actions: [[String: Any]] = fixes.map { fix in
            let edit: [String: Any] = [
                "changes": [
                    uri: [
                        [
                            "range": Self.lspRange(from: fix.replacementRange),
                            "newText": fix.newText,
                        ]
                    ]
                ]
            ]
            return [
                "title": fix.title,
                "kind": "quickfix",
                "diagnostics": [Self.diagnostic(from: fix.diagnostic)],
                "edit": edit,
            ]
        }
        return GravityLanguageServerAction(outgoingMessages: [response(id: id, result: actions)])
    }

    private func didChangeWatchedFiles(params: [String: Any]) -> GravityLanguageServerAction {
        guard let changes = params["changes"] as? [[String: Any]] else {
            return GravityLanguageServerAction()
        }
        for change in changes {
            guard let uri = change["uri"] as? String else {
                continue
            }
            if change["type"] as? Int == 3 {
                workspace.removeFile(uri: uri)
            } else {
                workspace.refreshFile(uri: uri)
            }
        }
        return GravityLanguageServerAction()
    }

    private func publishDiagnostics(uri: String) -> GravityLanguageServerAction {
        let diagnostics = workspace.analysis(for: uri)?.diagnostics.map(Self.diagnostic(from:)) ?? []
        return GravityLanguageServerAction(outgoingMessages: [
            notification(
                method: "textDocument/publishDiagnostics",
                params: [
                    "diagnostics": diagnostics,
                    "uri": uri,
                ]
            )
        ])
    }

    private func response(id: Any, result: Any) -> [String: Any] {
        ["id": id, "jsonrpc": "2.0", "result": result]
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        [
            "error": ["code": code, "message": message],
            "id": id ?? NSNull(),
            "jsonrpc": "2.0",
        ]
    }

    private func methodNotFound(_ method: String, id: Any?) -> GravityLanguageServerAction {
        guard let id else {
            return GravityLanguageServerAction()
        }
        return GravityLanguageServerAction(outgoingMessages: [errorResponse(id: id, code: -32601, message: "Method not found: \(method)")])
    }

    private func notification(method: String, params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "method": method, "params": params]
    }

    private static func position(from value: Any?) -> GravitySourcePosition? {
        guard
            let value = value as? [String: Any],
            let line = value["line"] as? Int,
            let character = value["character"] as? Int,
            line >= 0,
            character >= 0
        else {
            return nil
        }
        return GravitySourcePosition(line: line, utf16Column: character)
    }

    private static func lspRange(from range: GravitySourceRange) -> [String: Any] {
        [
            "end": ["character": range.end.utf16Column, "line": range.end.line],
            "start": ["character": range.start.utf16Column, "line": range.start.line],
        ]
    }

    private static func completionItem(from item: GravityCompletion) -> [String: Any] {
        [
            "detail": item.detail,
            "kind": item.kind.rawValue,
            "label": item.label,
            "sortText": item.sortText,
            "textEdit": [
                "newText": item.insertText,
                "range": lspRange(from: item.replacementRange),
            ],
        ]
    }

    private static func diagnostic(from diagnostic: GravityDiagnostic) -> [String: Any] {
        [
            "message": diagnostic.message,
            "range": lspRange(from: diagnostic.range),
            "severity": diagnostic.severity.rawValue,
            "source": "gravity-lsp",
        ]
    }

    private static func documentSymbol(from symbol: GravitySymbol) -> [String: Any] {
        var result: [String: Any] = [
            "detail": symbol.detail,
            "kind": symbol.kind.rawValue,
            "name": symbol.name,
            "range": lspRange(from: symbol.range),
            "selectionRange": lspRange(from: symbol.selectionRange),
        ]
        if !symbol.members.isEmpty {
            result["children"] = symbol.members.map(documentSymbol(from:))
        }
        return result
    }

    private static func locationLink(from definition: GravityDefinition) -> [String: Any] {
        [
            "targetRange": lspRange(from: definition.range),
            "targetSelectionRange": lspRange(from: definition.selectionRange),
            "targetUri": definition.uri,
        ]
    }
}

extension GravityLanguageServerSession {
    private func languageFeature(method: String, id: Any?, params: [String: Any]) -> GravityLanguageServerAction {
        switch method {
        case "textDocument/hover":
            hover(id: id, params: params)
        case "textDocument/signatureHelp":
            signatureHelp(id: id, params: params)
        default:
            semanticTokens(id: id, params: params)
        }
    }

    private func semanticTokens(id: Any?, params: [String: Any]) -> GravityLanguageServerAction {
        guard
            let id,
            let document = params["textDocument"] as? [String: Any],
            let uri = document["uri"] as? String
        else {
            return GravityLanguageServerAction(outgoingMessages: id.map { [errorResponse(id: $0, code: -32602, message: "Invalid semantic token parameters")] } ?? [])
        }
        return GravityLanguageServerAction(outgoingMessages: [
            response(id: id, result: ["data": Self.semanticTokenData(workspace.semanticTokens(uri: uri))])
        ])
    }

    private func hover(id: Any?, params: [String: Any]) -> GravityLanguageServerAction {
        guard
            let id,
            let document = params["textDocument"] as? [String: Any],
            let uri = document["uri"] as? String,
            let position = Self.position(from: params["position"])
        else {
            return GravityLanguageServerAction(outgoingMessages: id.map { [errorResponse(id: $0, code: -32602, message: "Invalid hover parameters")] } ?? [])
        }
        let result: Any =
            workspace.hover(uri: uri, position: position)
            .map { hover in
                [
                    "contents": ["kind": "markdown", "value": hover.contents],
                    "range": Self.lspRange(from: hover.range),
                ]
            } ?? NSNull()
        return GravityLanguageServerAction(outgoingMessages: [response(id: id, result: result)])
    }

    private func signatureHelp(id: Any?, params: [String: Any]) -> GravityLanguageServerAction {
        guard
            let id,
            let document = params["textDocument"] as? [String: Any],
            let uri = document["uri"] as? String,
            let position = Self.position(from: params["position"])
        else {
            return GravityLanguageServerAction(outgoingMessages: id.map { [errorResponse(id: $0, code: -32602, message: "Invalid signature help parameters")] } ?? [])
        }
        let result: Any =
            workspace.signatureHelp(uri: uri, position: position)
            .map { help in
                [
                    "activeParameter": help.activeParameter,
                    "activeSignature": 0,
                    "signatures": [["label": help.label]],
                ]
            } ?? NSNull()
        return GravityLanguageServerAction(outgoingMessages: [response(id: id, result: result)])
    }

    private static func semanticTokenData(_ tokens: [GravitySemanticToken]) -> [Int] {
        let tokenTypeIndices = Dictionary(uniqueKeysWithValues: GravitySemanticTokenKind.allCases.enumerated().map { ($0.element, $0.offset) })
        let segments =
            tokens
            .flatMap(semanticTokenSegments)
            .sorted { lhs, rhs in lhs.position < rhs.position }
        var previous = GravitySourcePosition(line: 0, utf16Column: 0)
        var data: [Int] = []
        data.reserveCapacity(segments.count * 5)
        for segment in segments {
            guard segment.length > 0, let typeIndex = tokenTypeIndices[segment.kind] else {
                continue
            }
            let deltaLine = segment.position.line - previous.line
            let deltaStart =
                deltaLine == 0
                ? segment.position.utf16Column - previous.utf16Column
                : segment.position.utf16Column
            data += [deltaLine, deltaStart, segment.length, typeIndex, 0]
            previous = segment.position
        }
        return data
    }

    private static func semanticTokenSegments(_ token: GravitySemanticToken) -> [SemanticTokenSegment] {
        if token.range.start.line == token.range.end.line {
            return [
                SemanticTokenSegment(
                    kind: token.kind,
                    length: token.range.end.utf16Column - token.range.start.utf16Column,
                    position: token.range.start
                )
            ]
        }
        return []
    }

    private struct SemanticTokenSegment {
        var kind: GravitySemanticTokenKind
        var length: Int
        var position: GravitySourcePosition
    }
}
