import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor agent global settings")
@MainActor
struct EditorAgentGlobalSettingsTests {
    @Test("global settings survive restart and override both existing and newly opened projects")
    func globalPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("preferences/agent.json")
        let settings = EditorAgentSettingsStore(fileURL: settingsURL)
        let firstURL = root.appendingPathComponent("First")
        let secondURL = root.appendingPathComponent("Second")
        let legacy = ProjectSystem.defaultProject(projectName: "Project")
        for url in [firstURL, secondURL] { try ProjectSystem.saveProject(legacy, at: url) }
        let first = EditorAgentViewModel(project: .init(name: "First", path: firstURL.path), settings: settings, service: FakeEditorAgentService())
        let service = FakeEditorAgentService()
        let second = EditorAgentViewModel(project: .init(name: "Second", path: secondURL.path), settings: settings, service: service)
        first.agentEnabled = true
        first.agentCommand = "/global-agent"
        first.agentPermissionMode = .deny
        first.saveAgentSettings()
        #expect(second.agentCommand == "/global-agent")
        #expect(second.agentPermissionMode == .deny)
        await second.loadSessions()
        second.activeSession?.upstreamSessionID = "old-provider-session"
        second.prompt = "Hello"
        await second.sendPromptAsync()
        let request = try #require(await service.recordedRequest())
        #expect(request.project.ai.agent == settings.configuration)
        #expect(request.projectURL.standardizedFileURL.path == secondURL.standardizedFileURL.path)
        #expect(request.session.upstreamSessionID == nil)
        #expect(try ProjectSystem.loadProject(at: firstURL) == legacy)
        #expect(try ProjectSystem.loadProject(at: secondURL) == legacy)
        let reloaded = EditorAgentSettingsStore(fileURL: settingsURL)
        let reopened = EditorAgentViewModel(project: .init(name: "First", path: firstURL.path), settings: reloaded, service: FakeEditorAgentService())
        #expect(reopened.agentCommand == "/global-agent")
        #expect(reloaded.configuration == settings.configuration)
    }

    @Test("first configured legacy project migrates once and later projects cannot override it")
    func migration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let settings = EditorAgentSettingsStore(fileURL: url)
        try settings.migrateIfNeeded(AdaProjectAgent())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let legacy = AdaProjectAgent(enabled: true, target: .init(command: "/legacy", arguments: ["a,b"]), permissionMode: .deny)
        try settings.migrateIfNeeded(legacy)
        let reloaded = EditorAgentSettingsStore(fileURL: url)
        try reloaded.migrateIfNeeded(AdaProjectAgent(enabled: true, target: .init(command: "/other")))
        #expect(reloaded.configuration == legacy)
        var disabled = legacy
        disabled.enabled = false
        try reloaded.save(disabled)
        try reloaded.migrateIfNeeded(legacy)
        #expect(!reloaded.configuration.enabled)
    }

    @Test("agent can be selected and saved without a project")
    func settingsWithoutProject() async throws {
        let settings = EditorAgentSettingsStore()
        let model = EditorAgentViewModel(project: nil, settings: settings, service: FakeEditorAgentService())
        let entry = EditorInstalledAgent(id: "global", name: "Global", version: "1", target: .init(command: "/global"))
        await model.connectCatalogAgent(installed: entry)
        #expect(model.isCatalogAgentSelected(entry))
        model.agentPermissionMode = .deny
        model.saveAgentSettings()
        #expect(settings.configuration.permissionMode == .deny)
        #expect(model.settingsStatusMessage.contains("all projects"))
    }
}
