import Foundation
import MCP

@MainActor
final class EditorAgentGravityMCPTools {
    static let shared = EditorAgentGravityMCPTools()

    private init() {}

    static func tools() -> [Tool] {
        [
            Tool(
                name: "editor.gravity.diagnostics",
                description: "Run the editor's Gravity LSP analysis on an open .ada/.gravity document or project source file. Positions in results are zero-based UTF-16 LSP positions.",
                inputSchema: objectSchema(properties: ["path": pathProperty()]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "editor.gravity.completion",
                description: "Get Gravity LSP completion items at a zero-based UTF-16 position in an .ada/.gravity file.",
                inputSchema: objectSchema(properties: ["path": pathProperty(), "line": .object(["type": "integer"]), "character": .object(["type": "integer", "description": "Zero-based UTF-16 code-unit offset, as used by LSP."])], required: ["line", "character"]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "editor.gravity.hover",
                description: "Get Gravity LSP hover documentation at a zero-based UTF-16 position in an .ada/.gravity file.",
                inputSchema: objectSchema(properties: ["path": pathProperty(), "line": .object(["type": "integer"]), "character": .object(["type": "integer", "description": "Zero-based UTF-16 code-unit offset, as used by LSP."])], required: ["line", "character"]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "editor.gravity.definition",
                description: "Resolve a Gravity LSP definition at a zero-based UTF-16 position. Returns the target file and LSP ranges.",
                inputSchema: objectSchema(properties: ["path": pathProperty(), "line": .object(["type": "integer"]), "character": .object(["type": "integer", "description": "Zero-based UTF-16 code-unit offset, as used by LSP."])], required: ["line", "character"]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            )
        ]
    }

    func handle(name: String, arguments: [String: Value]) async -> CallTool.Result? {
        do {
            let payload: String
            switch name {
            case "editor.gravity.diagnostics": payload = try await diagnostics(path: arguments["path"]?.stringValue)
            case "editor.gravity.completion": payload = try await completions(path: arguments["path"]?.stringValue, arguments: arguments)
            case "editor.gravity.hover": payload = try await hover(path: arguments["path"]?.stringValue, arguments: arguments)
            case "editor.gravity.definition": payload = try await definition(path: arguments["path"]?.stringValue, arguments: arguments)
            default: return nil
            }
            return .init(content: [.text(text: payload, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
        }
    }

    private func diagnostics(path: String?) async throws -> String {
        let (viewModel, fileURL, text) = try source(path: path)
        await viewModel.workspaceService.configureSourceWorkspace(projectURL: try requireProjectURL(viewModel))
        let analysis = await viewModel.workspaceService.adaScriptAnalysis(fileURL: fileURL, text: text)
        let results = analysis.diagnostics.map { diagnostic in
            [
                "path": diagnostic.filePath,
                "severity": diagnostic.severity.rawValue,
                "message": diagnostic.message,
                "source": diagnostic.source,
                "range": lspRange(diagnostic.range, text: text)
            ] as [String: Any]
        }
        return try json(["path": relativePath(fileURL, projectURL: try requireProjectURL(viewModel)), "diagnostics": results])
    }

    private func completions(path: String?, arguments: [String: Value]) async throws -> String {
        let (viewModel, fileURL, text) = try source(path: path)
        let position = try sourcePosition(arguments: arguments, text: text)
        await viewModel.workspaceService.configureSourceWorkspace(projectURL: try requireProjectURL(viewModel))
        let items = await viewModel.workspaceService.completions(fileURL: fileURL, language: .ada, text: text, position: position)
        return try json([
            "path": relativePath(fileURL, projectURL: try requireProjectURL(viewModel)),
            "items": items.map { item in
                [
                    "label": item.label,
                    "detail": item.detail as Any? ?? NSNull(),
                    "insertText": item.insertText,
                    "kind": String(describing: item.kind),
                    "sortText": item.sortText as Any? ?? NSNull(),
                    "replacementRange": item.replacementRange.map { lspRange($0, text: text) } as Any? ?? NSNull()
                ] as [String: Any]
            }
        ])
    }

    private func hover(path: String?, arguments: [String: Value]) async throws -> String {
        let (viewModel, fileURL, text) = try source(path: path)
        let position = try sourcePosition(arguments: arguments, text: text)
        await viewModel.workspaceService.configureSourceWorkspace(projectURL: try requireProjectURL(viewModel))
        let value = await viewModel.workspaceService.hover(fileURL: fileURL, language: .ada, text: text, position: position)
        return try json([
            "path": relativePath(fileURL, projectURL: try requireProjectURL(viewModel)),
            "contents": value?.contents as Any? ?? NSNull(),
            "range": value?.range.map { lspRange($0, text: text) } as Any? ?? NSNull()
        ])
    }

    private func definition(path: String?, arguments: [String: Value]) async throws -> String {
        let (viewModel, fileURL, text) = try source(path: path)
        let position = try sourcePosition(arguments: arguments, text: text)
        await viewModel.workspaceService.configureSourceWorkspace(projectURL: try requireProjectURL(viewModel))
        let targets = await viewModel.workspaceService.definition(fileURL: fileURL, language: .ada, text: text, position: position)
        return try json([
            "path": relativePath(fileURL, projectURL: try requireProjectURL(viewModel)),
            "targets": targets.map { target in
                [
                    "path": target.filePath,
                    "uri": target.uri,
                    "range": lspRange(target.range, text: target.content ?? ""),
                    "selectionRange": lspRange(target.selectionRange, text: target.content ?? ""),
                    "documentation": target.documentation as Any? ?? NSNull()
                ] as [String: Any]
            }
        ])
    }

    private func source(path: String?) throws -> (EditorViewModel, URL, String) {
        guard
            let viewModel = EditorAgentMCPTools.shared.activeViewModel,
            let projectURL = viewModel.projectURL
        else {
            throw EditorGravityMCPError.noOpenProject
        }

        let relative: String
        if let path, !path.isEmpty {
            relative = path
        } else if case let .text(document)? = viewModel.workbench.activeDocument,
                  document.language == .ada {
            relative = document.relativePath
        } else {
            throw EditorGravityMCPError.noActiveGravityDocument
        }

        guard !relative.hasPrefix("/"), ["ada", "gravity"].contains(URL(fileURLWithPath: relative).pathExtension.lowercased()) else {
            throw EditorGravityMCPError.invalidSourcePath(relative)
        }
        let projectPath = projectURL.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = projectURL.appendingPathComponent(relative).standardizedFileURL
        let resolvedPath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath.hasPrefix(projectPath + "/") else {
            throw EditorGravityMCPError.invalidSourcePath(relative)
        }

        if let document = viewModel.workbench.openDocuments.compactMap({ document -> EditorTextDocument? in
            if case let .text(text) = document, text.relativePath == relative, text.language == .ada { return text }
            return nil
        }).first, let absolutePath = document.absolutePath {
            return (viewModel, URL(fileURLWithPath: absolutePath).standardizedFileURL, document.content)
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw EditorGravityMCPError.sourceNotFound(relative)
        }
        do {
            return (viewModel, candidate, try String(contentsOf: candidate, encoding: .utf8))
        } catch {
            throw EditorGravityMCPError.sourceReadFailed(relative, error.localizedDescription)
        }
    }

    private func sourcePosition(arguments: [String: Value], text: String) throws -> EditorSourceLocation {
        guard let line = arguments["line"]?.intValue, let character = arguments["character"]?.intValue, line >= 0, character >= 0 else {
            throw EditorGravityMCPError.invalidPosition
        }
        return EditorGravityLanguageService.editorLocation(lspLine: line, utf16Character: character, text: text)
    }

    private func requireProjectURL(_ viewModel: EditorViewModel) throws -> URL {
        guard let projectURL = viewModel.projectURL else { throw EditorGravityMCPError.noOpenProject }
        return projectURL
    }

    private func relativePath(_ fileURL: URL, projectURL: URL) -> String {
        String(fileURL.standardizedFileURL.path.dropFirst(projectURL.standardizedFileURL.path.count + 1))
    }

    private func lspRange(_ range: EditorSourceRange, text: String) -> [String: Any] {
        let start = EditorGravityLanguageService.lspPosition(from: range.start, text: text)
        let end = EditorGravityLanguageService.lspPosition(from: range.end, text: text)
        return [
            "start": ["line": start.line, "character": start.utf16Column],
            "end": ["line": end.line, "character": end.utf16Column]
        ]
    }

    private static func pathProperty() -> Value {
        .object(["type": .string("string"), "description": .string("Project-relative .ada or .gravity path. Defaults to the active Gravity document.")])
    }

    private static func objectSchema(properties: [String: Value] = [:], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(Value.string)) }
        return .object(schema)
    }

    private func json(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private enum EditorGravityMCPError: Error, LocalizedError {
    case noOpenProject
    case noActiveGravityDocument
    case invalidSourcePath(String)
    case sourceNotFound(String)
    case sourceReadFailed(String, String)
    case invalidPosition

    var errorDescription: String? {
        switch self {
        case .noOpenProject: "Open an Ada project in Ada Editor first."
        case .noActiveGravityDocument: "Open a .ada or .gravity source file, or provide path."
        case let .invalidSourcePath(path): "Invalid project-relative Gravity source path: \(path)."
        case let .sourceNotFound(path): "Gravity source file was not found: \(path)."
        case let .sourceReadFailed(path, message): "Could not read Gravity source \(path): \(message)"
        case .invalidPosition: "Provide a non-negative zero-based LSP line and UTF-16 character offset."
        }
    }
}
