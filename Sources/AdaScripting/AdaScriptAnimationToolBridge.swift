import AdaAnimation
import AdaScriptCompilerCore
import Foundation

/// Detached work published by a successful synchronous Tool callback.
public struct AdaScriptAnimationToolJob: Sendable {
    public let id: String
    public let request: AnimationAuthoringRequest
}

/// Accessed only by the owning main-actor runtime under the shared VM lock.
/// Queues values and bounded JSON; it never retains an editor service or scene.
final class AdaScriptAnimationToolBridge {
    let permissions: Set<AdaScriptToolPermission>
    let apiVersion: Int
    private var results: [String: String] = [:]
    private var terminal: Set<String> = []
    private var staged: [AdaScriptAnimationToolJob] = []
    private var consumed: Set<String> = []
    private var pending: [AdaScriptAnimationToolJob] = []

    init(permissions: Set<AdaScriptToolPermission>, apiVersion: Int) {
        self.permissions = permissions
        self.apiVersion = apiVersion
    }

    var hasStagedJobs: Bool { !staged.isEmpty }
    func begin() { staged = []; consumed = [] }

    func finish(success: Bool) {
        if success {
            pending.append(contentsOf: staged)
            for id in consumed { results[id] = nil; terminal.remove(id) }
        } else {
            for job in staged { results[job.id] = nil }
        }
        staged = []; consumed = []
    }

    func submit(_ text: String) throws -> String {
        guard apiVersion == 2, permissions.contains(.animationRead) else { throw failure("API 2 and editor.animations.read are required.") }
        guard text.utf8.count <= 65_536, staged.count < 8, results.count < 16 else {
            throw failure("Animation jobs support 64 KiB requests, 8 submissions per callback and 16 retained jobs; poll completed jobs to release them.")
        }
        let request = try JSONDecoder().decode(AnimationAuthoringRequest.self, from: Data(text.utf8))
        if request.action.writesResource, !permissions.contains(.animationWrite) { throw failure("editor.animations.write is required.") }
        if request.action.requiresPreviewPermission, !permissions.contains(.animationPreview) { throw failure("editor.animations.preview is required.") }
        if request.action.requiresSceneWritePermission, !permissions.contains(.documentWrite) { throw failure("editor.documents.write is required to bind animations.") }
        let id = UUID().uuidString
        results[id] = #"{"status":"pending"}"#
        staged.append(.init(id: id, request: request))
        return id
    }

    func poll(_ id: String) throws -> String {
        guard apiVersion == 2, permissions.contains(.animationRead), let result = results[id], !consumed.contains(id) else {
            throw failure("Unknown, consumed or unavailable animation job.")
        }
        if terminal.contains(id) { consumed.insert(id) }
        return result
    }

    func takePending() -> [AdaScriptAnimationToolJob] {
        defer { pending = [] }
        return pending
    }

    func complete(_ id: String, responseJSON: String) throws {
        guard results[id] != nil, !terminal.contains(id) else { return }
        guard responseJSON.utf8.count <= 1_048_576,
            let object = try JSONSerialization.jsonObject(with: Data(responseJSON.utf8)) as? [String: Any],
            ["completed", "failed"].contains(object["status"] as? String ?? "") else { throw failure("Invalid animation job response.") }
        results[id] = responseJSON
        terminal.insert(id)
    }

    func retire() { results = [:]; terminal = []; staged = []; consumed = []; pending = [] }
    private func failure(_ text: String) -> AdaScriptError { .invalidManifest(text) }
}
