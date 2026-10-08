import Foundation
import Observation

/// App-wide connection preferences. Project files remain readable for one-time migration.
@Observable
@MainActor
final class EditorAgentSettingsStore {
    static let shared = EditorAgentSettingsStore(
        fileURL:
            FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AdaEditor/Agents/settings.json")
    )

    private(set) var configuration = AdaProjectAgent()
    var agentEnabled = false
    var agentCommand = ""
    var agentArguments = ""
    var agentWorkingDirectory = ""
    var agentEnvironment = ""
    var agentSkillsDirectories: [String] = []
    var agentPermissionMode = AdaProjectAgentPermissionMode.allowOnce
    private(set) var loadError: String?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var hasSavedSettings = false

    /// A nil URL provides an isolated in-memory store for previews and tests.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            hasSavedSettings = true
            do {
                configuration = try JSONDecoder().decode(AdaProjectAgent.self, from: Data(contentsOf: fileURL))
            } catch {
                loadError = "Unable to load global agent settings: \(error.localizedDescription)"
            }
        }
        loadDraft()
    }

    func migrateIfNeeded(_ legacy: AdaProjectAgent) throws {
        guard !hasSavedSettings, legacy.target.command?.isEmpty == false else {
            return
        }
        try save(legacy)
    }

    func save(_ configuration: AdaProjectAgent) throws {
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(configuration).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        self.configuration = configuration
        hasSavedSettings = true
        loadError = nil
        loadDraft()
    }

    private func loadDraft() {
        agentEnabled = configuration.enabled
        agentCommand = configuration.target.command ?? ""
        agentArguments = configuration.target.arguments.joined(separator: "\n")
        agentWorkingDirectory = configuration.target.cwd ?? ""
        agentEnvironment = configuration.target.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        agentSkillsDirectories = configuration.skillsDirectories
        agentPermissionMode = configuration.permissionMode
    }
}
