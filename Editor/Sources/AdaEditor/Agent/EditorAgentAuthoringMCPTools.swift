import Foundation
import MCP

/// Desktop and mobile share the same knowledge and native asset services.
@MainActor
enum EditorAgentAuthoringMCPTools {
    static func tools() -> [Tool] {
        EditorAgentKnowledgeTools.tools() + EditorAgentAssetTools.tools().filter {
            // Desktop scene edits must enter the open document's revision/undo path.
            // Image analysis requires a provider callback installed by the mobile host.
            !["editor.scene.asset.assign", "editor.image.read"].contains($0.name)
        }
    }

    static func handle(name: String, arguments: [String: Value]) async -> CallTool.Result? {
        guard let tool = tools().first(where: { $0.name == name }) else {
            return nil
        }
        do {
            guard let viewModel = EditorAgentMCPTools.shared.activeViewModel, let projectURL = viewModel.projectURL else {
                throw AuthoringError("Open an Ada project in Ada Studio first.")
            }
            if tool.annotations?.readOnlyHint != true {
                let paths = [arguments["path"]?.stringValue, arguments["destination"]?.stringValue, arguments["previewPath"]?.stringValue].compactMap { $0 }
                let targets = Set(paths.map { projectURL.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL })
                let dirty = viewModel.workbench.openDocuments.contains { document in
                    let file = projectURL.appendingPathComponent(document.relativePath).resolvingSymlinksInPath().standardizedFileURL
                    return document.isDirty && targets.contains(file)
                }
                guard !dirty else { throw AuthoringError("Save the target document before editing its asset file with a tool.") }
            }
            let result = try await execute(name: name, arguments: arguments, projectURL: projectURL)
            if tool.annotations?.readOnlyHint != true { viewModel.refreshProjectFiles(logsRefresh: false) }
            return result
        } catch {
            return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
        }
    }

    static func execute(name: String, arguments: [String: Value], projectURL: URL) async throws -> CallTool.Result {
        let payload: [String: Any]
        if EditorAgentKnowledgeTools.tools().contains(where: { $0.name == name }) {
            payload = try EditorAgentKnowledge.query(name: name, arguments: arguments)
        } else {
            payload = try await EditorAgentAssetToolService(projectURL: projectURL).execute(name: name, arguments: arguments)
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return .init(content: [.text(text: try EditorAgentToolEncoding.string(data), annotations: nil, _meta: nil)], isError: false)
    }

    private struct AuthoringError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
