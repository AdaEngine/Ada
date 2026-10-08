import Foundation
import Testing

@testable import AdaEditor

@Suite("Agent command and skill completion")
@MainActor
struct EditorAgentCompletionTests {
    private var skill: EditorAgentSkill {
        .init(
            id: "ada-coding",
            name: "Ada coding",
            description: "Work on code",
            localPath: "/tmp/SKILL.md",
            userInvocable: true,
            allowedTools: [],
            instructions: "Use AdaScript"
        )
    }

    @Test("slash lists and filters agent commands alongside invocable skills")
    func slashSearch() {
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
        model.availableSkills = [skill]
        model.sessionConfiguration.commands = [.init(name: "compact", description: "Compact this conversation")]
        model.promptBinding.wrappedValue = "/"
        #expect(Set(model.autocompleteSuggestions.map(\.kind)) == ["Command", "Skill"])
        model.promptBinding.wrappedValue = "/co"
        #expect(model.autocompleteSuggestions.contains(.command(.init(name: "compact", description: "Compact this conversation"))))
        model.promptBinding.wrappedValue = "/ada"
        #expect(model.autocompleteSuggestions == [.skill(skill)])
        #expect(model.acceptCompletion())
        #expect(model.prompt == "/ada-coding ")
    }

    @Test("at completion includes files and skills and only replaces the token at the caret")
    func mentionsAndCaret() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Completion"), at: root)
        try "code".write(to: root.appendingPathComponent("ada-source.swift"), atomically: true, encoding: .utf8)
        let model = EditorAgentViewModel(project: .init(name: "Completion", path: root.path), settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
        model.availableSkills = [skill]
        model.promptBinding.wrappedValue = "Use @ada then continue"
        model.updatePromptCaret(.init(line: 0, column: 8), text: model.prompt)
        #expect(Set(model.autocompleteSuggestions.map(\.kind)) == ["File", "Skill"])
        model.insertAutocomplete(.skill(skill))
        #expect(model.prompt == "Use @skill:ada-coding  then continue")
        #expect(model.promptCompletionFocus?.start.column == "Use @skill:ada-coding ".count)
        model.promptBinding.wrappedValue = "@"
        #expect(model.autocompleteSuggestions.contains(.skill(skill)))
    }

    @Test("selected skills reach the request; agent commands remain unchanged")
    func requestContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Completion"), at: root)
        let directory = root.appendingPathComponent(".skills/ada-coding")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nname: Ada coding\ndescription: Work on code\n---\nUse AdaScript".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let service = FakeEditorAgentService()
        let model = EditorAgentViewModel(project: .init(name: "Completion", path: root.path), settings: EditorAgentSettingsStore(), service: service)
        await model.loadSessions()
        model.prompt = "Use @skill:ada-coding please"
        await model.sendPromptAsync()
        #expect(await service.recordedRequest()?.skills.contains { $0.id == "ada-coding" } == true)
        model.sessionConfiguration.commands = [.init(name: "compact", description: "Compact")]
        model.prompt = "/compact keep the plan"
        await model.sendPromptAsync()
        #expect(await service.recordedRequest()?.prompt == "/compact keep the plan")
        model.prompt = "/ada-coding fix it"
        await model.sendPromptAsync()
        #expect(await service.recordedRequest()?.prompt == "fix it")
    }

    @Test("old stored session configuration still decodes")
    func legacyConfiguration() throws {
        let old = Data("{\"agentName\":\"Test\",\"selectors\":[]}".utf8)
        #expect(try JSONDecoder().decode(EditorAgentSessionConfiguration.self, from: old).commands.isEmpty)
    }
}
