#if os(macOS)
import AdaA2UI
@_spi(AdaEngine) import AdaEngine
import Darwin
import Foundation
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorAgentA2UITransportTests {
    @Test func failedConnectionTerminatesItsAgentProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("A2UIFailedConnection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("agent.pid")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/a2ui-acp-agent.py")
        var project = ProjectSystem.defaultProject(projectName: "FailedConnection", buildSystem: .adaScript)
        project.ai.agent.enabled = true
        project.ai.agent.target = .init(command: "/usr/bin/python3", arguments: [fixture.path, "--fail-new", pidFile.path])
        let service = EditorACPAgentService()
        let request = EditorAgentRunRequest(project: project, projectURL: root, session: .init(id: "failed"), mode: .ask,
                                            prompt: "No prompt should run", attachments: [], sceneContext: nil, codeSelection: nil, skills: [])
        do {
            _ = try await service.connect(request, onEvent: { _ in }, onProjectFileChanged: { _ in })
            Issue.record("Fixture connection should fail")
        } catch {
            let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
            for _ in 0..<30 {
                if kill(pid, 0) != 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(kill(pid, 0) != 0)
        }
        await service.shutdown()
    }

    @Test func promptCompletionWaitsForBurstNotificationsAndASlowUISink() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "A2UITransport")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("A2UITransport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/a2ui-acp-agent.py")
        var project = ProjectSystem.defaultProject(projectName: "Transport", buildSystem: .adaScript)
        project.ai.agent.enabled = true
        project.ai.agent.target = .init(command: "/usr/bin/python3", arguments: [fixture.path])
        let probe = root.appendingPathComponent("delegate.txt")
        try "delegate-alive".write(to: probe, atomically: true, encoding: .utf8)
        project.ai.agent.target.arguments += ["--probe-client", probe.path]
        let service = EditorACPAgentService()
        let ui = EditorAgentA2UISession(session: .init(id: "transport"))
        ui.beginRun(agentIdentity: project.ai.agent.target.sessionIdentity)
        let sink = A2UITransportSink(ui: ui)
        let request = EditorAgentRunRequest(project: project, projectURL: root, session: .init(id: "transport"), mode: .ask,
                                            prompt: "Present an NPC form", attachments: [], sceneContext: nil, codeSelection: nil, skills: [])
        do {
            // Connection setup returns before the agent calls the client delegate.
            _ = try await service.connect(request, onEvent: { _ in }, onProjectFileChanged: { _ in })
            await Task.yield()
            let result = try await service.send(request, onEvent: { event in
                try? await Task.sleep(for: .milliseconds(30))
                await sink.receive(event)
            }, onProjectFileChanged: { _ in })
            ui.finishRun(cancelled: false)
            #expect(result.assistantText.hasSuffix("```"))
            #expect(ui.eventErrors.isEmpty)
            #expect(ui.client.surfaces["npc-config"]?.scene.document.root.children.count == 7)
            #expect(ui.records["npc-config"]?.state == .ready)
            await service.shutdown()
        } catch {
            await service.shutdown()
            throw error
        }
    }
}
@MainActor
private final class A2UITransportSink {
    private var events: [EditorAgentEvent] = []
    let ui: EditorAgentA2UISession
    init(ui: EditorAgentA2UISession) { self.ui = ui }
    func receive(_ event: EditorAgentEvent) {
        EditorAgentEventReducer.upsert(event, into: &events)
        if let merged = events.first(where: { $0.id == event.id }) { ui.receive(merged) }
    }
}
#endif
