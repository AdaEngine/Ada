import AdaA2UI
@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import AdaUIDescription
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorAgentA2UITests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "A2UIChat")))
        }
    }

    @Test func fragmentedBlocksPreserveProseAndOrdinaryCodeFences() throws {
        var stream = EditorAgentA2UIStream()
        let source = "Before\n```swift\nlet label = \"```a2ui\"\n```\n```a2ui\n{\"version\":\"v0.9.1\"}\n```\nAfter"
        var frames: [Data] = []
        for character in source { frames += try stream.append(String(character)).map { try $0.get() } }
        frames += try stream.finish().map { try $0.get() }
        #expect(frames.count == 1)
        #expect(stream.displayText == "Before\n```swift\nlet label = \"```a2ui\"\n```\nAfter")
    }

    @Test func concatenatedPlannerAndFinalReplyStillRendersTheForm() throws {
        let ui = EditorAgentA2UISession(session: .init(id: "session"))
        ui.beginRun(agentIdentity: "agent")
        let source = "Planner output ends here.```a2ui\n" + EditorA2UIFixture.formLines.joined(separator: "\n") + "\n```"
        for end in source.indices {
            ui.receive(assistant(String(source[...end])))
        }
        ui.finishRun(cancelled: false)
        #expect(ui.client.surfaces["npc-config"] != nil)
        #expect(ui.records["npc-config"]?.state == .ready)
        #expect(ui.displayTexts["reply"] == "Planner output ends here.\n")
        #expect(ui.eventErrors.isEmpty)
    }

    @Test func nestedFenceExamplesDoNotHideTheActualAgentForm() throws {
        let ui = EditorAgentA2UISession(session: .init(id: "session"))
        ui.beginRun(agentIdentity: "agent")
        let prose = "Example:\n````text\n```a2ui\nexample only\n```\n````\nPlanner ends here."
        let source = prose + "```a2ui\n" + EditorA2UIFixture.formLines.joined(separator: "\n") + "\n```"
        for end in source.indices { ui.receive(assistant(String(source[...end]))) }
        ui.finishRun(cancelled: false)
        #expect(ui.client.surfaces["npc-config"] != nil)
        #expect(ui.displayTexts["reply"] == prose + "\n")
        #expect(ui.eventErrors.isEmpty)
    }

    @Test func fullMessageUpdatesDoNotReplayPreviouslyAppliedEnvelopes() throws {
        let ui = EditorAgentA2UISession(session: .init(id: "session"))
        ui.beginRun(agentIdentity: "agent")
        let first = "```a2ui\n" + EditorA2UIFixture.formLines[0] + "\n"
        ui.receive(assistant(first))
        #expect(ui.client.surfaces["npc-config"] != nil)
        ui.receive(assistant(first + EditorA2UIFixture.formLines[1] + "\n```"))
        ui.finishRun(cancelled: false)
        #expect(ui.eventErrors.isEmpty)
        #expect(ui.records["npc-config"]?.state == .ready)
        #expect(ui.displayTexts["reply"] == "")
    }

    @Test func invalidUpdatesAndCancellationKeepTheWorkingFormVisible() throws {
        let ui = makeSession()
        let previous = try #require(ui.client.surfaces["npc-config"]).scene.document
        ui.beginRun(agentIdentity: "agent")
        ui.receive(assistant("```a2ui\n" + #"{"version":"v0.9.1","updateComponents":{"surfaceId":"npc-config","components":[{"id":"npc-name","component":"Imaginary"}]}}"# + "\n```", id: "invalid"))
        #expect(ui.client.surfaces["npc-config"]?.scene.document == previous)
        #expect(ui.eventErrors["invalid"] != nil)
        ui.receive(assistant("```a2ui\n" + #"{"version":"v0.9.1","updateDataModel":{"surfaceId":"npc-config","path":"/npc/name","value":"Updated"}}"# + "\n```", id: "update"))
        ui.finishRun(cancelled: true)
        #expect(ui.records["npc-config"]?.state == .cancelled)
        #expect(ui.client.surfaces["npc-config"] != nil)
    }

    @Test func localEditsPersistAndRestoreWithoutReplayingServerDefaults() throws {
        let ui = makeSession()
        let surface = try #require(ui.client.surfaces["npc-config"])
        let input = try #require(surface.scene.document.root.children.first { $0.type == "TextField" })
        let name = try #require(input.arguments["text"]?.binding)
        surface.scene.context.binding(name).wrappedValue = .string("Local NPC")
        #expect(ui.records["npc-config"]?.state == .ready)
        var session = EditorAgentSession(id: "session")
        session.a2uiSurfaces = ui.persistedRecords
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(EditorAgentSession.self, from: data)
        let restored = EditorAgentA2UISession(session: decoded)
        #expect(restored.records["npc-config"]?.state == .ready)
        #expect(restored.client.surfaces["npc-config"]?.scene.context.value(name) == .string("Local NPC"))
        #expect(restored.client.surfaces["npc-config"]?.generation != surface.generation)
    }

    @Test func chatFormSubmissionReturnsToTheSameSessionAndOpensAnEditablePreview() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "A2UI", buildSystem: .adaScript), at: root)
        let settings = EditorAgentSettingsStore()
        var configuration = AdaProjectAgent()
        configuration.enabled = true
        configuration.target.command = "/fixture-agent"
        try settings.save(configuration)
        let service = EditorA2UIFixtureService()
        let agent = EditorAgentViewModel(project: .init(name: "A2UI", path: root.path), settings: settings, service: service)
        await agent.loadSessions()
        let editor = EditorViewModel(project: .init(name: "A2UI", path: root.path), agent: agent)
        agent.prompt = "Create an NPC configuration form"
        await agent.sendPromptAsync()
        let sessionID = try #require(agent.activeSession?.id)
        let ui = try #require(agent.a2ui.sessions[sessionID])
        let container = UIContainerView(rootView: EditorAgentTranscript(viewModel: agent).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 560, height: 700)
        container.layoutSubviews()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("a2ui.npc-config.npc-name"))
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .a, modifiers: [.control], status: .down, time: 0, isRepeated: false))
        container.onTextInputEvent(TextInputEvent(window: .empty, text: "Ada Guide", action: .insert, time: 0))
        agent.prompt = "Keep this unsent draft"
        for _ in 0..<3 { await Task.yield() }
        container.layoutSubviews()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("a2ui.npc-config.generate"))
        for _ in 0..<200 {
            if await service.count() == 2, !agent.isSending { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await service.count() == 2)
        let requests = await service.recordedRequests()
        #expect(requests[0].session.id == requests[1].session.id)
        #expect(requests[1].session.upstreamSessionID == "fixture-upstream")
        #expect(requests[1].a2uiAction != nil)
        #expect(EditorAgentPromptContext.text(for: requests[1]).contains("Ada Guide"))
        #expect(agent.prompt == "Keep this unsent draft")
        #expect(ui.records["npc-config"]?.state == .submitted)
        #expect(ui.records["npc-preview"]?.state == .ready)
        for _ in 0..<3 { await Task.yield() }
        container.layoutSubviews()
        _ = try container.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.Agent.A2UI.OpenDesigner.npc-preview"))
        container.layoutSubviews()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.A2UI.OpenDesigner.npc-preview"))
        guard case let .ui(document)? = editor.workbench.activeDocument else {
            Issue.record("Generated preview did not open in the real workbench as .ui")
            return
        }
        #expect(document.absolutePath != nil)
        #expect(try UISceneDocument.decode(document.content).root.type == "VStack")
        #expect(FileManager.default.fileExists(atPath: try #require(document.absolutePath)))
        let saved = try await EditorAgentSessionStore(projectURL: root).loadSession(id: sessionID)
        #expect(saved.a2uiSurfaces?.contains { $0.id == "npc-preview" } == true)
    }

    @Test func oldProviderSurfacesCannotSubmitToANewProvider() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Ownership", buildSystem: .adaScript), at: root)
        let settings = EditorAgentSettingsStore()
        var config = AdaProjectAgent()
        config.enabled = true
        config.target.command = "/original-agent"
        try settings.save(config)
        let service = EditorA2UIFixtureService()
        let agent = EditorAgentViewModel(project: .init(name: "Ownership", path: root.path), settings: settings, service: service)
        await agent.loadSessions()
        agent.prompt = "Create form"
        await agent.sendPromptAsync()
        let sessionID = try #require(agent.activeSession?.id)
        let ui = try #require(agent.a2ui.sessions[sessionID])
        config.target.command = "/different-agent"
        try settings.save(config)
        ui.client.surfaces["npc-config"]?.scene.context.perform("event:generate")
        for _ in 0..<3 { await Task.yield() }
        #expect(await service.count() == 1)
        #expect(ui.records["npc-config"]?.error?.contains("another") == true)
    }

    @Test func previewWriterRejectsSymlinkEscapeAndNeverOverwritesAnExistingAsset() throws {
        let root = try directory()
        let outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let doc = UISceneDocument(root: .init(type: "Text", arguments: ["text": .init(value: .string("Preview"))]))
        let first = try EditorAgentA2UIPreviewWriter.write(doc, surfaceID: "../../npc", projectURL: root)
        let second = try EditorAgentA2UIPreviewWriter.write(doc, surfaceID: "../../npc", projectURL: root)
        #expect(first != second)
        #expect(try String(contentsOf: root.appendingPathComponent(first), encoding: .utf8) == doc.encodedYAML())
        let assets = root.appendingPathComponent("Assets")
        try FileManager.default.removeItem(at: assets)
        try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: outside)
        #expect(throws: EditorAgentServiceError.self) { try EditorAgentA2UIPreviewWriter.write(doc, surfaceID: "npc", projectURL: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func anUpdatedSubmittedSurfaceCanAcceptTheNextInteraction() throws {
        let ui = makeSession()
        var submission: EditorAgentA2UISubmission?
        ui.onSubmission = { submission = $0 }
        ui.client.surfaces["npc-config"]?.scene.context.perform("event:generate")
        #expect(ui.records["npc-config"]?.state == .submitting)
        let sent = try #require(submission)
        ui.beginRun(agentIdentity: "agent")
        ui.receive(assistant("```a2ui\n" + #"{"version":"v0.9.1","updateDataModel":{"surfaceId":"npc-config","path":"/npc/name","value":"Updated"}}"# + "\n```", id: "next"))
        ui.finishRun(cancelled: false, submission: sent)
        #expect(ui.records["npc-config"]?.state == .ready)
    }

    @Test func editsInTwoChatsAreSavedIndependently() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "TwoChats", buildSystem: .adaScript), at: root)
        let agent = EditorAgentViewModel(project: .init(name: "TwoChats", path: root.path), settings: EditorAgentSettingsStore(), service: EditorA2UIFixtureService())
        await agent.loadSessions()
        agent.prompt = "First form"
        await agent.sendPromptAsync()
        let firstID = try #require(agent.activeSession?.id)
        let first = try #require(agent.a2ui.sessions[firstID])
        try await agent.createSession(connectAutomatically: false)
        agent.prompt = "Second form"
        await agent.sendPromptAsync()
        let secondID = try #require(agent.activeSession?.id)
        let second = try #require(agent.a2ui.sessions[secondID])
        for (ui, name) in [(first, "First local edit"), (second, "Second local edit")] {
            let surface = try #require(ui.client.surfaces["npc-config"])
            let field = try #require(surface.scene.document.root.children.first { $0.type == "TextField" })
            surface.scene.context.binding(try #require(field.arguments["text"]?.binding)).wrappedValue = .string(name)
        }
        try await Task.sleep(for: .milliseconds(350))
        let store = EditorAgentSessionStore(projectURL: root)
        for (id, name) in [(firstID, "First local edit"), (secondID, "Second local edit")] {
            let saved = try await store.loadSession(id: id)
            let restored = EditorAgentA2UISession(session: saved)
            let surface = try #require(restored.client.surfaces["npc-config"])
            let field = try #require(surface.scene.document.root.children.first { $0.type == "TextField" })
            let bindingName = try #require(field.arguments["text"]?.binding)
            #expect(surface.scene.context.value(bindingName) == .string(name))
        }
    }

    private func makeSession() -> EditorAgentA2UISession {
        let ui = EditorAgentA2UISession(session: .init(id: "session"))
        ui.beginRun(agentIdentity: "agent")
        ui.receive(assistant(EditorA2UIFixture.form))
        ui.finishRun(cancelled: false)
        return ui
    }

    private func assistant(_ text: String, id: String = "reply") -> EditorAgentEvent {
        .init(id: id, kind: .message, message: .init(role: .assistant, segments: [.init(kind: .text, text: text)]))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudioA2UI-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum EditorA2UIFixture {
    static let formLines = [
        #"{"version":"v0.9.1","createSurface":{"surfaceId":"npc-config","catalogId":"https://adaengine.org/a2ui/catalogs/forms/v1","sendDataModel":true}}"#,
        #"{"version":"v0.9.1","updateComponents":{"surfaceId":"npc-config","components":[{"id":"root","component":"Column","children":["npc-name","generate"]},{"id":"npc-name","component":"TextField","text":{"path":"/npc/name"},"placeholder":"NPC name"},{"id":"generate","component":"Button","text":"Generate preview","action":{"event":{"name":"generate_npc_preview","context":{"name":{"path":"/npc/name"}}}}}]}}"#,
        #"{"version":"v0.9.1","updateDataModel":{"surfaceId":"npc-config","value":{"npc":{"name":"Guide"}}}}"#
    ]
    static let form = "Configure your NPC.\n```a2ui\n" + formLines.joined(separator: "\n") + "\n```\n"
    static let preview = "Here is an editable preview.\n```a2ui\n" + [
        #"{"version":"v0.9.1","createSurface":{"surfaceId":"npc-preview","catalogId":"https://adaengine.org/a2ui/catalogs/forms/v1"}}"#,
        #"{"version":"v0.9.1","updateComponents":{"surfaceId":"npc-preview","components":[{"id":"root","component":"Column","children":["title"]},{"id":"title","component":"Text","text":"Ada Guide dialog"}]}}"#
    ].joined(separator: "\n") + "\n```\n"
}

private actor EditorA2UIFixtureService: EditorAgentServicing {
    private var requests: [EditorAgentRunRequest] = []
    func count() -> Int { requests.count }
    func recordedRequests() -> [EditorAgentRunRequest] { requests }
    func connect(_ request: EditorAgentRunRequest, onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
                 onProjectFileChanged: @escaping @Sendable (String) async -> Void) async throws -> EditorAgentSessionConfiguration { .empty }
    func send(_ request: EditorAgentRunRequest, onEvent: @escaping @Sendable (EditorAgentEvent) async -> Void,
              onProjectFileChanged: @escaping @Sendable (String) async -> Void) async throws -> EditorAgentRunResult {
        requests.append(request)
        let text = request.a2uiAction == nil ? EditorA2UIFixture.form : EditorA2UIFixture.preview
        let id = UUID().uuidString
        for part in text.split(separator: "\n", omittingEmptySubsequences: false) {
            await onEvent(.init(id: id, kind: .message, message: .init(role: .assistant, segments: [.init(kind: .text, text: String(part) + "\n")]), isDelta: true))
        }
        return .init(upstreamSessionID: "fixture-upstream", assistantText: text, stopReason: "end_turn", configuration: .empty)
    }
    func setConfiguration(sessionID: String, selectorID: String, valueID: String) async throws -> EditorAgentSessionConfiguration { .empty }
    func resolvePermission(requestID: String, optionID: String?) async {}
    func cancel(sessionID: String) async {}
    func shutdown() async {}
}
