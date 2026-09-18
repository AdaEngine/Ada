import Foundation

private struct EditorDocumentSession: Codable {
    let relativePath: String
}

extension EditorViewModel {
    private var documentSessionURL: URL? {
        projectURL?.appendingPathComponent(".ada/workspace/editor-session.json")
    }

    func rememberActiveProjectDocument() {
        guard let document = workbench.activeDocument, let sessionURL = documentSessionURL else {
            return
        }
        if case .git = document {
            return
        }
        let path = document.relativePath
        guard
            path != lastRememberedProjectFile,
            projectSidebar.items.contains(where: { !$0.isFolder && $0.relativePath == path })
        else {
            return
        }
        do {
            let data = try JSONEncoder().encode(EditorDocumentSession(relativePath: path))
            try fileManager.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: sessionURL, options: .atomic)
            lastRememberedProjectFile = path
        } catch {
            appendOutput("Unable to remember the active file: \(error.localizedDescription)")
        }
    }

    func restoreProjectDocument() {
        guard let projectURL, let sessionURL = documentSessionURL else {
            return
        }
        let saved = (try? Data(contentsOf: sessionURL)).flatMap { try? JSONDecoder().decode(EditorDocumentSession.self, from: $0) }
        lastRememberedProjectFile = saved?.relativePath
        let metadata = try? ProjectSystem.loadProject(at: projectURL, fileManager: fileManager)
        let candidates = [saved?.relativePath, metadata?.runtime.entry.scene, metadata?.editor.startupScene, "Assets/Scenes/Main.ascn"]
            .compactMap { $0 }
        let item =
            candidates.lazy
            .compactMap { path in
                self.projectSidebar.items.first { !$0.isFolder && $0.relativePath == path }
            }
            .first ?? projectSidebar.items.first { $0.kind == .scene }
        guard let item else {
            return
        }
        // Use the normal opening path to initialize previews, inspector and source tooling.
        openProjectItem(item)
    }
}
