#if os(macOS) || os(Windows)
import AdaInput
@_spi(Internal) @testable import AdaUI
import Foundation
import Testing

@testable import AdaEditor

extension EditorAgentChatUITests {
    @Test("Send shows a partial ACP reply before completion and restores the composer on success or failure", arguments: [false, true])
    func sendStreamsReply(fails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentReply-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("agent.py")
        let continueGate = root.appendingPathComponent("continue")
        let finishGate = root.appendingPathComponent("finish")
        try Self.replyAgentScript.write(to: script, atomically: true, encoding: .utf8)
        var project = ProjectSystem.defaultProject(projectName: "Agent Reply")
        project.ai.agent.enabled = true
        project.ai.agent.target = .init(
            command: EditorHostTools.executable("python3", windowsName: "python.exe"),
            arguments: [script.path, continueGate.path, finishGate.path, fails ? "fail" : "succeed"]
        )
        try ProjectSystem.saveProject(project, at: root)
        let service = EditorACPAgentService()
        let model = EditorAgentViewModel(
            project: .init(name: "Agent Reply", path: root.path),
            settings: EditorAgentSettingsStore(),
            service: service,
            notifications: EditorNotificationCenter()
        )
        await model.loadSessions()
        let sessionID = try #require(model.activeSessionID)
        let container = makeContainer(model)
        let sendIdentifier = "AdaEditor.Agent.Send"
        let send = UINodeSelector.accessibilityIdentifier(sendIdentifier)
        let stop = UINodeSelector.accessibilityIdentifier("AdaEditor.Agent.Stop")
        let prompt = "Say hello"
        let firstReply = "Hello"
        let intermediateReply = "Hello, Ada"
        let finalReply = "Hello, Ada and мир."
        let rejection = "The test provider rejected the prompt."

        do {
            try #require(await waitForChat(in: container) { model.currentConnectionState == .ready("UI test agent") }, "ACP fixture connected")
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Prompt"))
            container.onTextInputEvent(TextInputEvent(window: .empty, text: prompt, action: .insert, time: 0))
            try #require(await waitForChat(in: container) { (try? container.uiNode(matching: send).isInteractable) == true }, "Send enabled after typing")
            _ = try container.uiTapNode(matching: send)

            try #require(await waitForChat(in: container) { chatLabels(in: container).contains(firstReply) }, "The first delta appeared in the open chat")
            #expect(chatLabels(in: container).contains(prompt))
            #expect(try container.uiNode(matching: stop).isInteractable)
            #expect(container.uiFindNodes(matching: send).isEmpty)

            let assistantID = try #require(model.activeSession?.events.first { $0.message?.role == .assistant }?.id)
            let reply = UINodeSelector.accessibilityIdentifier("AdaEditor.Agent.Event.\(assistantID)")
            let firstNode = try container.uiNode(matching: reply)
            try Data().write(to: continueGate)
            try #require(await waitForChat(in: container) { chatLabels(in: container).contains(intermediateReply) }, "The second delta extended the reply")
            #expect(try container.uiNode(matching: reply).runtimeId == firstNode.runtimeId)
            #expect(!chatLabels(in: container).contains(firstReply))
            #expect(try container.uiNode(matching: stop).isInteractable)
            #expect(container.uiFindNodes(matching: send).isEmpty)

            // Keep completion blocked until both intermediate states have rendered.
            try Data().write(to: finishGate)
            let finished = try await waitForChat(in: container) {
                let labels = chatLabels(in: container)
                let renderedOutcome = fails ? labels.contains { $0.contains(rejection) } : labels.contains(finalReply)
                return renderedOutcome && !container.uiFindNodes(matching: send).isEmpty
            }
            try #require(finished, "The final transcript and Send appeared after the ACP turn")
            #expect(try container.uiNode(matching: reply).runtimeId == firstNode.runtimeId)
            #expect(container.uiFindNodes(matching: stop).isEmpty)
            let sendNode = try #require(chatNode(in: container, identifier: sendIdentifier))
            let sendButton = try #require(sendNode.uiCollectNodes { $0 is ButtonViewNode }.first)
            #expect(!sendButton.canBecomeFocused)

            let labels = chatLabels(in: container)
            if fails {
                #expect(labels.filter { $0 == intermediateReply }.count == 1)
            } else {
                #expect(labels.filter { $0 == finalReply }.count == 1)
                #expect(!labels.contains(intermediateReply))
            }
            let saved = try await EditorAgentSessionStore(projectURL: root).loadSession(id: sessionID)
            let replies = saved.events.compactMap(\.message).filter { $0.role == .assistant }
            #expect(replies.count == 1)
            #expect(replies.first?.segments.first?.text == (fails ? "Hello, **Ada**" : "Hello, **Ada** and **мир**."))
            #expect(saved.events.last?.kind == (fails ? .error : .runStatus))
            if !fails {
                #expect(saved.events.last?.details == "end_turn")
            }
        } catch {
            await service.shutdown()
            throw error
        }
        await service.shutdown()
    }

    private func chatLabels(in container: UIContainerView<EditorAgentSidebar>) -> [String] {
        guard let transcript = chatNode(in: container, identifier: "AdaEditor.Agent.Transcript") else {
            return []
        }
        return transcript.uiCollectNodes { $0 is TextViewNode && $0.frame.height > 0 }
            .compactMap { ($0 as? TextViewNode)?.selectableText }
    }

    private func chatNode(in container: UIContainerView<EditorAgentSidebar>, identifier: String) -> ViewNode? {
        container.viewTree.rootNode.uiCollectNodes { $0.accessibilityIdentifier == identifier }.first
    }

    private func waitForChat(in container: UIContainerView<EditorAgentSidebar>, until condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        repeat {
            container.layoutIfNeeded()
            container.update(1 / 60)
            if condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline
        return false
    }

    private static let replyAgentScript = #"""
        import json, pathlib, sys, time

        continue_gate = pathlib.Path(sys.argv[1])
        finish_gate = pathlib.Path(sys.argv[2])
        fails = sys.argv[3] == "fail"

        def emit(**message):
            print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)

        def chunk(text):
            emit(method="session/update", params={"sessionId": "ui", "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}
            }})

        def wait_for_gate(gate):
            deadline = time.monotonic() + 15
            while not gate.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            if not gate.exists():
                sys.exit(f"Chat never released the {gate.name} gate")

        for line in sys.stdin:
            request = json.loads(line)
            method = request["method"]
            if "id" not in request:
                continue
            request_id = request["id"]
            if method == "initialize":
                result = {"protocolVersion": 1, "agentCapabilities": {"loadSession": False},
                          "agentInfo": {"name": "UI test agent", "version": "1"}}
            elif method == "session/new":
                result = {"sessionId": "ui"}
            elif method == "session/prompt":
                if not any("Say hello" in block.get("text", "").splitlines() for block in request["params"]["prompt"]):
                    emit(id=request_id, error={"code": -32602, "message": "Unexpected composer text"})
                    continue
                chunk("Hello")
                wait_for_gate(continue_gate)
                chunk(", **Ada**")
                wait_for_gate(finish_gate)
                if fails:
                    emit(id=request_id, error={"code": -32603, "message": "The test provider rejected the prompt."})
                    continue
                chunk(" and **мир**.")
                result = {"stopReason": "end_turn"}
            else:
                result = {}
            emit(id=request_id, result=result)
        """#
}
#endif
