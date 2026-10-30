import Foundation
import MCP

/// Reuses the native editor's tool implementations, with project ownership and dirty-document guards.
@MainActor
final class EditorCloudToolHost {
    nonisolated static let planTools: Set<String> = [
        "editor_files_list", "editor_file_read", "editor_project_context", "editor_scene_list", "editor_scene_list_open", "editor_scene_get", "editor_asset_list",
        "editor_gravity_diagnostics", "editor_gravity_completion", "editor_gravity_hover", "editor_gravity_definition", "editor_skills_list", "editor_skills_read", "editor_docs_read",
        "editor_docs_search", "editor_api_describe", "editor_components_describe", "editor_examples_list", "editor_examples_read", "editor_output_read", "editor_task_status",
        "editor_runtime_inspect", "editor_play_inspect", "editor_model_inspect", "editor_audio_inspect", "editor_web_search", "editor_web_fetch",
    ]
    let projectURL: URL
    private let mobile: EditorMobileAgentToolService
    private let web: EditorAgentWebToolService
    private let isMobile: Bool

    init(projectURL: URL, mobile: EditorMobileAgentToolService? = nil, webClient: any EditorWebHTTPClient = EditorWebURLSessionClient()) {
        self.projectURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
        self.mobile = mobile ?? EditorMobileAgentToolService(projectURL: projectURL)
        self.web = EditorAgentWebToolService(projectURL: projectURL, client: webClient)
        self.isMobile = mobile != nil
    }
    deinit { Task { @MainActor [mobile] in mobile.finish() } }
    func tools() throws -> [EditorCloudAgentTool] {
        let inventory =
            isMobile
            ? EditorMobileAgentTools.tools() + [MobileEditorTool.build]
            : EditorAgentMCPTools.tools() + EditorAgentWorkspaceMCPTools.tools() + EditorAgentGravityMCPTools.tools()
                + EditorAgentAuthoringMCPTools.tools() + EditorAgentWebTools.tools()
        return try (Self.fileTools + inventory).filter {
            // Publishing and provider-backed image operations require their own explicit flows.
            !["editor.community.submit", "editor.image.read", "editor.image.generate", "editor.image.edit"].contains($0.name)
        }.map { tool in
            let toolName = tool.name
            let name = tool.name.replacingOccurrences(of: ".", with: "_")
            let schema = try JSONDecoder().decode(EditorCloudValue.self, from: JSONEncoder().encode(tool.inputSchema))
            return EditorCloudAgentTool(
                name: name,
                definition: ["type": "function", "function": ["name": .string(name), "description": .string(tool.description ?? ""), "parameters": schema]],
                readOnly: tool.annotations?.readOnlyHint == true,
                invoke: { [self] arguments in try await invoke(toolName, arguments: arguments) })
        }
    }
    private func invoke(_ name: String, arguments: EditorCloudValue) async throws -> String {
        try Task.checkCancellation()
        let args = try JSONDecoder().decode([String: Value].self, from: JSONEncoder().encode(arguments))
        if name == "editor.files.list" { return try listFiles() }
        if ["editor.file.read", "editor.file.write", "editor.file.patch"].contains(name) { return try file(name, args) }
        if isMobile {
            let result: EditorMobileAgentToolResult
            if name == "editor.build.start" { result = mobile.build() } else { result = await mobile.handle(name: name, arguments: args) }
            guard result.ok else { throw EditorAgentServiceError.providerFailure(result.payload) }
            return result.payload
        }
        try requireDesktopProject()
        if EditorAgentWebTools.contains(name) {
            let value = try await web.execute(name: name, arguments: args)
            return try EditorAgentToolEncoding.string(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        }
        let result: CallTool.Result?
        if let value = EditorAgentMCPTools.shared.handle(name: name, arguments: args) {
            result = value
        } else if let value = EditorAgentWorkspaceMCPTools.shared.handle(name: name, arguments: args) {
            result = value
        } else if let value = await EditorAgentWorkspaceMCPTools.shared.handleAsync(name: name, arguments: args) {
            result = value
        } else if let value = await EditorAgentGravityMCPTools.shared.handle(name: name, arguments: args) {
            result = value
        } else {
            result = await EditorAgentAuthoringMCPTools.handle(name: name, arguments: args)
        }
        guard let result else { throw EditorAIError.invalidResponse }
        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        guard result.isError != true else { throw EditorAgentServiceError.providerFailure(text) }
        return text
    }
    private func requireDesktopProject() throws {
        guard EditorAgentMCPTools.shared.activeViewModel?.projectURL?.resolvingSymlinksInPath().standardizedFileURL.pathComponents == projectURL.pathComponents else {
            throw EditorAgentServiceError.providerFailure("A different project is open. Return to this project before continuing.")
        }
    }
    private func resolve(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let roots: Set<String> = ["Sources", "Scenes", "Assets", "Tests", "Docs", "Documentation"]
        let notes: Set<String> = ["AGENTS.md", "DESIGN.md", "PLAN.md", "PROGRESS.md", "README.md"]
        guard !path.isEmpty, path.utf8.count <= 512, !path.contains("\\"), !path.contains(":"), !path.unicodeScalars.contains(where: { $0.value < 32 }),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            roots.contains(String(parts[0])) || notes.contains(path) || path.hasPrefix(".ada/skills/")
        else {
            throw EditorAgentServiceError.pathOutsideProject(path)
        }
        // Resolving the full URL alone does not follow an existing parent link when
        // the final file does not exist yet. Reject links component by component.
        var result = projectURL
        for part in parts {
            result.appendPathComponent(String(part))
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: result.path)) == nil else {
                throw EditorAgentServiceError.pathOutsideProject(path)
            }
        }
        result = result.standardizedFileURL
        guard result.path.hasPrefix(projectURL.path + "/"), !result.pathComponents.contains(".git") else { throw EditorAgentServiceError.pathOutsideProject(path) }
        return result
    }
    private func file(_ name: String, _ args: [String: Value]) throws -> String {
        guard let path = args["path"]?.stringValue else { throw EditorAIError.invalidResponse }
        let url = try resolve(path)
        if !isMobile {
            try requireDesktopProject()
            if EditorAgentMCPTools.shared.activeViewModel?.workbench.openDocuments.contains(where: { $0.relativePath == path && $0.isDirty }) == true {
                throw EditorAgentServiceError.providerFailure("Save the open document before changing it with Ada AI.")
            }
        }
        let extensions: Set<String> = ["ada", "ascn", "ui", "md", "txt", "json", "glsl", "swift"]
        guard extensions.contains(url.pathExtension.lowercased()) else { throw EditorAIError.invalidResponse }
        if name == "editor.file.read" {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 128_000 else { throw EditorAIError.invalidResponse }
            return try String(contentsOf: url, encoding: .utf8)
        }
        let text: String
        if name == "editor.file.patch" {
            let old = try String(contentsOf: url, encoding: .utf8)
            guard let match = args["oldText"]?.stringValue, !match.isEmpty, old.components(separatedBy: match).count == 2,
                let replacement = args["newText"]?.stringValue
            else { throw EditorAIError.invalidResponse }
            text = old.replacingOccurrences(of: match, with: replacement)
        } else {
            guard !FileManager.default.fileExists(atPath: url.path), let value = args["content"]?.stringValue else {
                throw EditorAgentServiceError.providerFailure("Use editor.file.patch to change an existing file.")
            }
            text = value
        }
        guard text.utf8.count <= 512_000 else { throw EditorAIError.invalidResponse }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return "Saved " + path
    }
    private func listFiles() throws -> String {
        guard let entries = FileManager.default.enumerator(at: projectURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw EditorAIError.invalidResponse
        }
        var result: [String] = []
        for case let url as URL in entries {
            let path = String(url.path.dropFirst(projectURL.path.count + 1))
            if (try? resolve(path)) == nil {
                entries.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { result.append(path) }
            if result.count >= 512 { break }
        }
        return result.sorted().joined(separator: "\n")
    }
    private static var fileTools: [Tool] {
        let path: Value = .object(["type": "string"])
        let text: Value = .object(["type": "string"])
        return [
            EditorMobileAgentTools.tool("editor.files.list", "List project source, scene and asset paths."),
            EditorMobileAgentTools.tool("editor.file.read", "Read a project text file before changing it.", ["path": path], ["path"]),
            EditorMobileAgentTools.tool(
                "editor.file.write", "Create a NEW project text file. Use patch for existing files.", ["path": path, "content": text], ["path", "content"], readOnly: false),
            EditorMobileAgentTools.tool(
                "editor.file.patch", "Replace exactly one occurrence in an existing text file. Read it first.", ["path": path, "oldText": text, "newText": text],
                ["path", "oldText", "newText"], readOnly: false),
        ]
    }
    private enum MobileEditorTool {
        static var build: Tool { EditorMobileAgentTools.tool("editor.build.start", "Compile AdaScript and validate project scenes.", readOnly: false) }
    }
}
