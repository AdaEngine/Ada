import Foundation
import Testing

@testable import AdaEditor

#if os(macOS)
    @Suite("Editor agent ACP streaming", .serialized)
    struct EditorAgentStreamingTests {
        @Test("connected session keeps model selection and delivers deltas before prompt completion")
        func streamingProcess() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentStream-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let script = root.appendingPathComponent("agent.py")
            try Self.agentScript.write(to: script, atomically: true, encoding: .utf8)
            var project = ProjectSystem.defaultProject(projectName: "Streaming")
            project.ai.agent.enabled = true
            project.ai.agent.target = AdaProjectAgentTarget(command: "/usr/bin/python3", arguments: [script.path])
            let request = EditorAgentRunRequest(
                project: project,
                projectURL: root,
                session: EditorAgentSession(),
                mode: .build,
                prompt: "test",
                attachments: [],
                sceneContext: nil,
                codeSelection: nil,
                skills: []
            )
            let service = EditorACPAgentService()
            let recorder = StreamingRecorder()
            let finished = root.appendingPathComponent("finished")
            let onEvent: @Sendable (EditorAgentEvent) async -> Void = { event in
                await recorder.record(event, beforeCompletion: !FileManager.default.fileExists(atPath: finished.path))
            }
            do {
                let connected = try await service.connect(request, onEvent: onEvent, onProjectFileChanged: { _ in })
                #expect(connected.selectors.first?.currentValueID == "a")
                let selected = try await service.setConfiguration(sessionID: request.session.id, selectorID: "model", valueID: "b")
                #expect(selected.selectors.first?.currentValueID == "b")
                let reconnected = try await service.connect(request, onEvent: onEvent, onProjectFileChanged: { _ in })
                #expect(reconnected.selectors.first?.currentValueID == "b")
                let result = try await service.send(request, onEvent: onEvent, onProjectFileChanged: { _ in })
                let chunks = await recorder.chunks
                #expect(chunks.map { $0.message?.segments.first?.text ?? "" } == ["Hello", " world"])
                #expect(Set(chunks.map(\.id)).count == 1)
                #expect(await recorder.receivedBeforeCompletion)
                #expect(result.assistantText == "Hello world")
                #expect(result.configuration.commands.map(\.name) == ["compact"])
                #expect(result.configuration.commands.first?.inputHint == "Optional focus")
                #expect(result.configuration.selectors.first?.currentValueID == "c")
                #expect(await recorder.configurations.last?.selectors.first?.currentValueID == "c")
                let secondRecorder = StreamingRecorder()
                let secondResult = try await service.send(
                    request,
                    onEvent: { event in
                        await secondRecorder.record(event, beforeCompletion: true)
                    },
                    onProjectFileChanged: { _ in }
                )
                #expect(secondResult.assistantText == "Hello world")
                #expect(await secondRecorder.chunks.count == 2)
                #expect(await recorder.chunks.count == 2)
                await service.shutdown()
            } catch {
                await service.shutdown()
                throw error
            }
        }

        @Test("Loading an ACP session does not append replayed history")
        func loadedSessionReplay() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentReplay-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let script = root.appendingPathComponent("agent.py")
            try Self.replayAgentScript.write(to: script, atomically: true, encoding: .utf8)
            var project = ProjectSystem.defaultProject(projectName: "Replay")
            project.ai.agent.enabled = true
            project.ai.agent.target = .init(command: "/usr/bin/python3", arguments: [script.path])
            var session = EditorAgentSession()
            session.upstreamSessionID = "previous-session"
            session.agentTargetIdentity = project.ai.agent.target.sessionIdentity
            let request = EditorAgentRunRequest(
                project: project, projectURL: root, session: session, mode: .build,
                prompt: "new prompt", attachments: [], sceneContext: nil,
                codeSelection: nil, skills: []
            )
            let service = EditorACPAgentService()
            let recorder = StreamingRecorder()
            let onEvent: @Sendable (EditorAgentEvent) async -> Void = { event in
                await recorder.record(event, beforeCompletion: true)
            }
            do {
                _ = try await service.connect(request, onEvent: onEvent, onProjectFileChanged: { _ in })
                #expect(await recorder.chunks.isEmpty)
                let result = try await service.send(request, onEvent: onEvent, onProjectFileChanged: { _ in })
                #expect(result.assistantText == "Fresh reply")
                #expect(await recorder.chunks.compactMap { $0.message?.segments.first?.text } == ["Fresh reply"])
                await service.shutdown()
            } catch {
                await service.shutdown()
                throw error
            }
        }

        @Test("A completed ACP run saves its original session without a completion notification")
        @MainActor
        func notificationSessionIdentity() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentNotifications-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let script = root.appendingPathComponent("agent.py")
            try Self.agentScript.write(to: script, atomically: true, encoding: .utf8)
            var project = ProjectSystem.defaultProject(projectName: "Notifications")
            project.ai.agent.enabled = true
            project.ai.agent.target = AdaProjectAgentTarget(command: "/usr/bin/python3", arguments: [script.path])
            try ProjectSystem.saveProject(project, at: root)
            let service = EditorACPAgentService()
            let center = EditorNotificationCenter()
            let model = EditorAgentViewModel(project: .init(name: "Notifications", path: root.path), settings: EditorAgentSettingsStore(), service: service, notifications: center)
            await model.loadSessions()
            let originalID = try #require(model.activeSession?.id)
            model.prompt = "test"
            let run = Task { await model.sendPromptAsync() }
            for _ in 0..<200 {
                if !center.activities.active.isEmpty {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!center.activities.active.isEmpty)
            #expect(model.activityState == .working)
            let activityID = try #require(center.activities.active.first?.id)
            center.activities.needsAttention(activityID, detail: "Approve tool", eventID: "glow-approval")
            #expect(model.activityState == .needsInput)
            center.activities.resume(activityID)
            #expect(model.activityState == .working)
            try await model.createSession()
            let selectedID = try #require(model.activeSession?.id)
            #expect(selectedID != originalID)
            await run.value
            #expect(model.activeSession?.id == selectedID)
            #expect(model.activeSession?.events.isEmpty == true)
            #expect(!center.notifications.contains { $0.id.hasSuffix(":result") })
            #expect(center.activities.all.first?.state == .completed)
            #expect(model.activityState == .completed)
            let store = EditorAgentSessionStore(projectURL: root)
            let saved = try await store.loadSession(id: originalID)
            #expect(
                saved.events.compactMap(\.message)
                    .contains { message in
                        message.role == .assistant && message.segments.contains { $0.text == "Hello world" }
                    }
            )
            await service.shutdown()
        }

        @Test("changing global connection settings replaces cached ACP sessions and rejects old provider IDs")
        func changedConnection() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwitch-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let script = root.appendingPathComponent("agent.py")
            try Self.agentScript.replacingOccurrences(of: "\"loadSession\":False", with: "\"loadSession\":True")
                .write(to: script, atomically: true, encoding: .utf8)
            var project = ProjectSystem.defaultProject(projectName: "Switch")
            project.ai.agent.enabled = true
            project.ai.agent.target = .init(command: "/usr/bin/python3", arguments: [script.path], environment: ["AGENT": "first"])
            var session = EditorAgentSession()
            let service = EditorACPAgentService()
            do {
                let first = EditorAgentRunRequest(
                    project: project,
                    projectURL: root,
                    session: session,
                    mode: .build,
                    prompt: "",
                    attachments: [],
                    sceneContext: nil,
                    codeSelection: nil,
                    skills: []
                )
                _ = try await service.connect(first, onEvent: { _ in }, onProjectFileChanged: { _ in })
                _ = try await service.setConfiguration(sessionID: session.id, selectorID: "model", valueID: "b")
                session.upstreamSessionID = "belongs-to-first"
                session.agentTargetIdentity = project.ai.agent.target.sessionIdentity
                project.ai.agent.target.environment = ["AGENT": "second"]
                let second = EditorAgentRunRequest(
                    project: project,
                    projectURL: root,
                    session: session,
                    mode: .build,
                    prompt: "",
                    attachments: [],
                    sceneContext: nil,
                    codeSelection: nil,
                    skills: []
                )
                let connected = try await service.connect(second, onEvent: { _ in }, onProjectFileChanged: { _ in })
                #expect(connected.selectors.first?.currentValueID == "a")
                project.ai.agent.enabled = false
                let disabled = EditorAgentRunRequest(
                    project: project,
                    projectURL: root,
                    session: session,
                    mode: .build,
                    prompt: "",
                    attachments: [],
                    sceneContext: nil,
                    codeSelection: nil,
                    skills: []
                )
                await #expect(throws: EditorAgentServiceError.self) {
                    try await service.connect(disabled, onEvent: { _ in }, onProjectFileChanged: { _ in })
                }
            } catch {
                await service.shutdown()
                throw error
            }
            await service.shutdown()
        }

        private static let agentScript = #"""
            import json, sys, time
            def emit(value):
                print(json.dumps(value), flush=True)
            def options(current):
                return [{"id":"model","name":"Model","category":"model","type":"select","currentValue":current,
                         "options":[{"value":v,"name":v.upper()} for v in ["a","b","c"]]}]
            def update(value):
                emit({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session","update":value}})
            for line in sys.stdin:
                req = json.loads(line)
                method = req.get("method")
                if method == "initialize":
                    result = {"protocolVersion":1,"agentCapabilities":{"loadSession":False},"agentInfo":{"name":"test","version":"1"}}
                elif method == "session/new":
                    result = {"sessionId":"session","configOptions":options("a")}
                elif method == "session/set_config_option":
                    result = {"configOptions":options(req["params"]["value"])}
                elif method == "session/prompt":
                    update({"sessionUpdate":"available_commands_update","availableCommands":[{"name":"compact","description":"Compact conversation","input":{"hint":"Optional focus"}}]})
                    for text in ["Hello", " world"]:
                        update({"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}})
                        time.sleep(0.2)
                    update({"sessionUpdate":"config_option_update","configOptions":options("c")})
                    time.sleep(0.2)
                    open("finished", "w").close()
                    result = {"stopReason":"end_turn"}
                else:
                    result = {}
                if "id" in req:
                    emit({"jsonrpc":"2.0","id":req["id"],"result":result})
            """#

        private static let replayAgentScript = #"""
            import json, sys
            def emit(value):
                print(json.dumps(value), flush=True)
            def message(text):
                emit({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"previous-session",
                    "update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}}}})
            for line in sys.stdin:
                req = json.loads(line)
                method = req.get("method")
                if method == "initialize":
                    result = {"protocolVersion":1,"agentCapabilities":{"loadSession":True},"agentInfo":{"name":"replay","version":"1"}}
                elif method == "session/load":
                    message("Old reply")
                    result = {"sessionId":"previous-session"}
                elif method == "session/prompt":
                    message("Fresh reply")
                    result = {"stopReason":"end_turn"}
                else:
                    result = {"sessionId":"previous-session"}
                if "id" in req:
                    emit({"jsonrpc":"2.0","id":req["id"],"result":result})
            """#
    }

    private actor StreamingRecorder {
        var chunks: [EditorAgentEvent] = []
        var configurations: [EditorAgentSessionConfiguration] = []
        var receivedBeforeCompletion = false

        func record(_ event: EditorAgentEvent, beforeCompletion: Bool) {
            if event.isDelta == true {
                chunks.append(event)
                receivedBeforeCompletion = receivedBeforeCompletion || beforeCompletion
            }
            if let configuration = event.configuration {
                configurations.append(configuration)
            }
        }
    }
#endif
