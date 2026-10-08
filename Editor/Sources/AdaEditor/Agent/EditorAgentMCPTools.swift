import Foundation
import MCP

enum EditorMCPServerAddress {
    static let host = "127.0.0.1"
    static let endpoint = "/mcp"

    static var port: Int {
        guard
            let value = CommandLine.arguments.first(where: { $0.hasPrefix("--mcp-port=") })?.split(separator: "=").last,
            let port = Int(value), (1...65535).contains(port)
        else {
            return 2510
        }
        return port
    }

    static var url: String { "http://\(host):\(port)\(endpoint)" }
}

@MainActor
final class EditorAgentMCPTools {
    static let shared = EditorAgentMCPTools()

    private weak var viewModel: EditorViewModel?

    var activeViewModel: EditorViewModel? { viewModel }

    private init() {}

    func activate(_ viewModel: EditorViewModel) {
        self.viewModel = viewModel
    }

    func deactivate(_ viewModel: EditorViewModel) {
        guard self.viewModel === viewModel else {
            return
        }
        self.viewModel = nil
    }

    static func tools() -> [Tool] {
        [
            Tool(
                name: "editor.project.context",
                description: "Get the opened Ada project, active document, and current editor build or play state.",
                inputSchema: objectSchema(),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "editor.scene.list_open",
                description: "List scene documents currently open in Ada Editor.",
                inputSchema: objectSchema(),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "editor.scene.get",
                description: "Read an open scene document, its revision, and its serialized scene YAML.",
                inputSchema: objectSchema(properties: ["path": .object(["type": "string", "description": "Project-relative path of an open scene. Defaults to the active scene."])]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "editor.scene.apply",
                description: "Apply validated structured operations to an open scene document. Supply its current revision; edits enter Ada Editor undo history and remain unsaved until normal autosave/save.",
                inputSchema: objectSchema(
                    properties: [
                        "path": .object(["type": "string", "description": "Project-relative path of an open scene. Defaults to the active scene."]),
                        "expectedRevision": .object(["type": "string", "description": "Revision returned by editor.scene.get."]),
                        "operations": .object([
                            "type": "array",
                            "description": "Apply operations in order. setComponent replaces the full payload, so include any fields that should be retained.",
                            "items": .object([
                                "type": "object",
                                "properties": .object([
                                    "op": .object(["type": "string", "enum": .array(["createEntity", "renameEntity", "setEntityEnabled", "reparentEntity", "deleteEntity", "addComponent", "setComponent", "removeComponent"].map(Value.string))]),
                                    "id": .object(["type": "string", "description": "Optional stable ID for createEntity."]),
                                    "entityID": .object(["type": "string"]),
                                    "name": .object(["type": "string"]),
                                    "parentID": .object(["type": ["string", "null"]]),
                                    "enabled": .object(["type": "boolean"]),
                                    "children": .object(["type": "string", "enum": .array(["cascade", "reparent"].map(Value.string))]),
                                    "typeName": .object(["type": "string", "description": "Registered component type name."]),
                                    "payload": .object(["type": "object", "description": "Component fields to set."]),
                                    "components": .object(["type": "object", "description": "Optional component payloads for createEntity."])
                                ]),
                                "required": .array([Value.string("op")])
                            ])
                        ])
                    ],
                    required: ["expectedRevision", "operations"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "editor.scene.undo",
                description: "Undo the most recent scene document edit in Ada Editor's normal undo history.",
                inputSchema: objectSchema(properties: ["path": .object(["type": "string", "description": "Project-relative path. Defaults to the active scene."])]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "editor.asset.list",
                description: "List project files under the Assets directory, optionally filtered by path or filename.",
                inputSchema: objectSchema(properties: ["query": .object(["type": "string", "description": "Optional case-insensitive path or filename filter."]), "limit": .object(["type": "integer", "description": "Maximum number of paths to return; defaults to 100 and is capped at 500."])]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            )
        ]
    }

    func handle(name: String, arguments: [String: Value]) -> CallTool.Result? {
        do {
            let result: String
            switch name {
            case "editor.project.context":
                result = try projectContext()
            case "editor.scene.list_open":
                result = try openScenes()
            case "editor.scene.get":
                result = try sceneSnapshot(path: arguments["path"]?.stringValue)
            case "editor.scene.apply":
                result = try applyScene(path: arguments["path"]?.stringValue, arguments: arguments)
            case "editor.scene.undo":
                result = try undoScene(path: arguments["path"]?.stringValue)
            case "editor.asset.list":
                result = try assets(query: arguments["query"]?.stringValue, limit: arguments["limit"]?.intValue)
            default:
                return nil
            }
            return .init(content: [.text(text: result, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
        }
    }

    private func projectContext() throws -> String {
        guard let viewModel, let project = viewModel.project else {
            throw EditorAgentMCPToolError.noOpenProject
        }
        let document = viewModel.workbench.activeDocument
        let activeDocument: Any
        if let document {
            activeDocument = ["title": document.title, "path": document.relativePath, "dirty": document.isDirty]
        } else {
            activeDocument = NSNull()
        }
        return try json([
            "project": project.name,
            "projectPath": project.path,
            "activeDocument": activeDocument,
            "workspaceStatus": viewModel.workspaceStatus.title,
            "playMode": String(describing: viewModel.playModeState),
            "model3D": EditorAgentModelToolService.capabilities,
            "authoringTools": EditorAgentAuthoringMCPTools.tools().map(\.name)
        ])
    }

    private func openScenes() throws -> String {
        let viewModel = try requireViewModel()
        let scenes = viewModel.workbench.openDocuments.compactMap { document -> [String: Any]? in
            guard case let .scene(scene) = document else { return nil }
            return ["path": scene.relativePath, "title": scene.title, "dirty": scene.isDirty, "active": scene.id == viewModel.workbench.activeDocumentID]
        }
        return try json(["scenes": scenes])
    }

    private func sceneSnapshot(path: String?) throws -> String {
        let viewModel = try requireViewModel()
        let document = try sceneDocument(path: path, in: viewModel)
        let content = document.content
        guard let model = document.sceneModel ?? EditorSceneFileLoader.model(from: content) else {
            throw EditorAgentMCPToolError.invalidScene(document.relativePath)
        }
        return try json(["path": document.relativePath, "revision": EditorAgentSceneToolService.revision(for: content), "yaml": try model.encodedYAML(), "dirty": document.isDirty])
    }

    private func applyScene(path: String?, arguments: [String: Value]) throws -> String {
        let viewModel = try requireViewModel()
        let document = try sceneDocument(path: path, in: viewModel)
        guard !document.isReadOnly else { throw EditorAgentMCPToolError.readOnlyScene(document.relativePath) }
        guard let expectedRevision = arguments["expectedRevision"]?.stringValue else { throw EditorAgentMCPToolError.missingArgument("expectedRevision") }
        let currentRevision = EditorAgentSceneToolService.revision(for: document.content)
        guard currentRevision == expectedRevision else { throw EditorAgentMCPToolError.staleRevision(expected: expectedRevision, actual: currentRevision) }
        guard case let .array(rawOperations)? = arguments["operations"], !rawOperations.isEmpty, rawOperations.count <= 100 else {
            throw EditorAgentMCPToolError.invalidOperations
        }
        let operations = try rawOperations.map(decodeOperation)
        guard let source = document.sceneModel ?? EditorSceneFileLoader.model(from: document.content) else {
            throw EditorAgentMCPToolError.invalidScene(document.relativePath)
        }
        guard let projectURL = viewModel.projectURL else { throw EditorAgentMCPToolError.noOpenProject }
        let service = EditorAgentSceneToolService(projectURL: projectURL)
        let model = try service.applying(operations: operations, to: source)
        var updated = document
        updated.sceneModel = model
        updated.content = try model.encodedYAML()
        updated.loadSummary = EditorSceneFileLoader.summary(from: updated.content)
        updated.isDirty = updated.content != updated.lastSavedContent
        updated.statusMessage = "Edited by agent"
        updated.errorMessage = nil
        viewModel.workbench.replaceSceneDocument(updated)
        return try json(["path": updated.relativePath, "previousRevision": currentRevision, "revision": EditorAgentSceneToolService.revision(for: updated.content), "yaml": updated.content, "dirty": updated.isDirty])
    }

    private func undoScene(path: String?) throws -> String {
        let viewModel = try requireViewModel()
        let document = try sceneDocument(path: path, in: viewModel)
        guard viewModel.workbench.activeDocumentID == document.id else {
            throw EditorAgentMCPToolError.sceneMustBeActive(document.relativePath)
        }
        guard viewModel.workbench.performDocumentHistory(redo: false), let restored = viewModel.workbench.activeSceneDocument else {
            throw EditorAgentMCPToolError.nothingToUndo
        }
        return try json(["path": restored.relativePath, "revision": EditorAgentSceneToolService.revision(for: restored.content), "yaml": restored.content, "dirty": restored.isDirty])
    }

    private func assets(query: String?, limit: Int?) throws -> String {
        let viewModel = try requireViewModel()
        guard let projectURL = viewModel.projectURL else { throw EditorAgentMCPToolError.noOpenProject }
        let assetsURL = projectURL.appendingPathComponent("Assets", isDirectory: true)
        let maximum = min(max(limit ?? 100, 1), 500)
        guard let enumerator = FileManager.default.enumerator(at: assetsURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return try json(["assets": [String]()])
        }
        let filter = query?.lowercased()
        let paths = enumerator.compactMap { $0 as? URL }.filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
            let relative = String(url.path.dropFirst(projectURL.path.count + 1))
            return filter.map { relative.lowercased().contains($0) } ?? true
        }.map { String($0.path.dropFirst(projectURL.path.count + 1)) }.sorted().prefix(maximum)
        return try json(["assets": Array(paths)])
    }

    private func decodeOperation(_ value: Value) throws -> EditorAgentSceneOperation {
        guard case let .object(fields) = value, let operation = fields["op"]?.stringValue else { throw EditorAgentMCPToolError.invalidOperations }
        func required(_ key: String) throws -> String {
            guard let value = fields[key]?.stringValue, !value.isEmpty else { throw EditorAgentMCPToolError.missingArgument(key) }
            return value
        }
        switch operation {
        case "createEntity":
            let name = try required("name")
            let parent = fields["parentID"]?.stringValue
            let components = try componentMap(fields["components"])
            return .createEntity(id: fields["id"]?.stringValue, name: name, parentID: parent, components: components)
        case "renameEntity": return .renameEntity(id: try required("entityID"), name: try required("name"))
        case "setEntityEnabled":
            guard case let .bool(enabled)? = fields["enabled"] else { throw EditorAgentMCPToolError.missingArgument("enabled") }
            return .setEntityEnabled(id: try required("entityID"), enabled: enabled)
        case "reparentEntity": return .reparentEntity(id: try required("entityID"), parentID: fields["parentID"]?.stringValue)
        case "deleteEntity":
            guard let children = EditorAgentSceneDeleteChildren(rawValue: fields["children"]?.stringValue ?? "cascade") else {
                throw EditorAgentMCPToolError.invalidArgument("children must be 'cascade' or 'reparent'.")
            }
            return .deleteEntity(id: try required("entityID"), children: children)
        case "addComponent": return .addComponent(entityID: try required("entityID"), typeName: try required("typeName"))
        case "setComponent": return .setComponent(entityID: try required("entityID"), typeName: try required("typeName"), payload: try componentPayload(fields["payload"]))
        case "removeComponent": return .removeComponent(entityID: try required("entityID"), typeName: try required("typeName"))
        default: throw EditorAgentMCPToolError.invalidOperation(operation)
        }
    }

    private func componentPayload(_ value: Value?) throws -> EditorComponentPayload {
        guard case let .object(values)? = value else { return [:] }
        return try values.mapValues(sceneValue)
    }

    private func componentMap(_ value: Value?) throws -> [String: EditorComponentPayload] {
        guard case let .object(values)? = value else { return [:] }
        var result: [String: EditorComponentPayload] = [:]
        for (typeName, payload) in values {
            result[typeName] = try componentPayload(payload)
        }
        return result
    }

    private func sceneValue(_ value: Value) throws -> EditorSceneValue {
        switch value {
        case .null: .null
        case let .bool(value): .bool(value)
        case let .int(value): .int(value)
        case let .double(value): .double(value)
        case let .string(value): .string(value)
        case let .array(values): .array(try values.map(sceneValue))
        case let .object(values): .object(try values.mapValues(sceneValue))
        }
    }

    private func sceneDocument(path: String?, in viewModel: EditorViewModel) throws -> EditorSceneDocument {
        let selected = path.map { path in viewModel.workbench.openDocuments.first { $0.relativePath == path } } ?? viewModel.workbench.activeDocument
        guard case let .scene(document)? = selected else { throw EditorAgentMCPToolError.sceneNotOpen(path ?? "active") }
        return document
    }

    private func requireViewModel() throws -> EditorViewModel {
        guard let viewModel, viewModel.project != nil else { throw EditorAgentMCPToolError.noOpenProject }
        return viewModel
    }

    private static func objectSchema(properties: [String: Value] = [:], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(Value.string)) }
        return .object(schema)
    }

    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private enum EditorAgentMCPToolError: Error, LocalizedError {
    case noOpenProject
    case sceneNotOpen(String)
    case invalidScene(String)
    case readOnlyScene(String)
    case staleRevision(expected: String, actual: String)
    case invalidOperations
    case invalidOperation(String)
    case invalidArgument(String)
    case missingArgument(String)
    case sceneMustBeActive(String)
    case nothingToUndo

    var errorDescription: String? {
        switch self {
        case .noOpenProject: "Open an Ada project in Ada Editor first."
        case let .sceneNotOpen(path): "Scene is not open in Ada Editor: \(path). Open it in the editor and retry."
        case let .invalidScene(path): "Could not decode the open scene: \(path)."
        case let .readOnlyScene(path): "Scene is read-only: \(path)."
        case let .staleRevision(expected, actual): "Scene changed since it was read. Expected revision \(expected), current revision is \(actual); read the scene again."
        case .invalidOperations: "Provide 1–100 valid scene operations."
        case let .invalidOperation(operation): "Unknown scene operation: \(operation)."
        case let .invalidArgument(message): message
        case let .missingArgument(name): "Missing required argument: \(name)."
        case let .sceneMustBeActive(path): "Select this scene before undoing it: \(path)."
        case .nothingToUndo: "There is no scene edit to undo."
        }
    }
}
