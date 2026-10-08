import Foundation
import Observation

/// Portable chat cards persist alongside the provider session, with guarded disk-scene Undo.
@MainActor @Observable
final class EditorMobileA2UIStore {
    let controller = EditorAgentA2UIController()
    private var projectURLs: [String: URL] = [:]
    private(set) var persistenceError: String?

    init(shouldPersist: Bool = true) {
        guard shouldPersist else {
            return
        }
        controller.onRecordsChanged = { [weak self] id, records in
            guard let self, let root = self.projectURLs[id] else {
                return
            }
            do {
                let url = try self.recordsURL(sessionID: id, root: root)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(records).write(to: url, options: .atomic)
                self.persistenceError = nil
            } catch { self.persistenceError = "Unable to save chat interface: \(error.localizedDescription)" }
        }
    }

    @discardableResult
    func prepare(sessionID: String, projectURL: URL, events: [EditorAgentEvent], identity: String?) -> EditorAgentA2UISession {
        if let previous = projectURLs[sessionID], previous.standardizedFileURL != projectURL.standardizedFileURL {
            controller.remove(sessionID: sessionID)
        }
        projectURLs[sessionID] = projectURL
        if let ui = controller.sessions[sessionID] {
            ui.reconcileEvents(events)
            return ui
        }
        var session = EditorAgentSession(id: sessionID, events: events)
        session.agentTargetIdentity = identity
        do {
            let url = try recordsURL(sessionID: sessionID, root: projectURL)
            if FileManager.default.fileExists(atPath: url.path) {
                session.a2uiSurfaces = try JSONDecoder().decode([EditorAgentA2UISurfaceRecord].self, from: Data(contentsOf: url))
            }
        } catch { persistenceError = "Unable to restore chat interface: \(error.localizedDescription)" }
        let ui = controller.restoreIfNeeded(session)
        ui.reconcileEvents(events)
        return ui
    }

    func performLocal(_ submission: EditorAgentA2UISubmission) -> Bool {
        guard let ui = controller.sessions[submission.sessionID] else {
            return false
        }
        return ui.performLocal(submission) { request in
            guard let root = projectURLs[submission.sessionID] else { throw EditorAgentA2UIToolRequest.Failure("The project was closed.") }
            let service = EditorAgentSceneToolService(projectURL: root)
            let path = try request.string("path")
            let snapshot = try service.snapshot(relativePath: path)
            let change = try service.apply(relativePath: path, expectedRevision: request.string("expectedRevision"), operations: request.operations(in: snapshot.model))
            return .init(path: path, revision: change.revision, changeID: change.changeID, message: "Applied to \(path)")
        }
    }

    func undo(surfaceID: String, sessionID: String) {
        guard let ui = controller.sessions[sessionID], let root = projectURLs[sessionID],
              let record = ui.records[surfaceID], record.state == .ready,
              let result = record.lastApplication, let changeID = result.changeID, let binding = record.revisionBinding else { return }
        do {
            let snapshot = try EditorAgentSceneToolService(projectURL: root).undo(changeID: changeID)
            try ui.updateLocalValue(.string(snapshot.revision), binding: binding, surfaceID: surfaceID)
            ui.clearLocalApplication(surfaceID: surfaceID)
        } catch { ui.setError(error.localizedDescription, surfaceID: surfaceID) }
    }

    func export(surfaceID: String, sessionID: String) throws -> String {
        guard let root = projectURLs[sessionID], let surface = controller.sessions[sessionID]?.client.surfaces[surfaceID] else {
            throw EditorAgentA2UIToolRequest.Failure("The interface is unavailable.")
        }
        return try EditorAgentA2UIPreviewWriter.write(surface.snapshot(), surfaceID: surfaceID, projectURL: root, fileManager: .default)
    }

    private func recordsURL(sessionID: String, root: URL) throws -> URL {
        let url = root.appendingPathComponent(".ada/chat-ui/\(EditorAgentSceneToolService.revision(for: sessionID)).json")
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw EditorAgentA2UIToolRequest.Failure("The chat interface store escapes the project.")
        }
        return url
    }
}
