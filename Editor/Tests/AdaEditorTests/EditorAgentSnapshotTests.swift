#if os(macOS) && canImport(SAGAMetal)
    @_spi(AdaEngine) import AdaEngine
    @_spi(Internal) @testable import AdaUI
    import Foundation
    import Math
    import Testing

    @testable import AdaEditor

    @MainActor
    @Suite("Agent chat screenshots on SAGA Metal", .serialized, .enabled(if: EditorUISnapshot.enabled))
    struct EditorAgentSnapshotTests {
        @Test func conversation() async throws {
            let renderer = try EditorUISnapshotRenderer()
            let events = [
                message("question", role: .user, text: "How do I configure the player's starting health?"),
                message("reply", text: """
                    ## Starting health

                    Set **Health** to `100` in the Inspector. [Read the guide](https://adaengine.org).

                    - Select the player entity.
                    - Enter the starting value.

                    > Keep Health positive while the player is active.

                    | Default configuration |
                    | --- |
                    | Health = 100 |

                    ---

                    ![Inspector preview](preview.png)

                    ```swift
                    player.health = 100
                    ```
                    """),
            ]
            let transcript = await mount(events, width: 460, height: 425)
            try requireVisible("AdaEditor.Agent.UserMessage.question", in: transcript)
            for block in ["Quote", "Table", "Code"] {
                try requireVisible("AdaEditor.Agent.Markdown.\(block)", in: transcript)
            }
            try EditorUISnapshot.check(try await renderer.render(transcript), named: "conversation-markdown")
        }

        @Test func multicolumnMarkdownTable() async throws {
            let renderer = try EditorUISnapshotRenderer()
            let reply = message("table", text: """
                | Component | Value | Notes |
                | --- | --- | --- |
                | **Health** | `100` | Длинное описание переносится внутри ячейки и задаёт высоту всей строки. |
                | Speed | `6` | Units per second |
                """)
            let transcript = await mount([reply], width: 600, height: 225)
            try requireVisible("AdaEditor.Agent.Markdown.Table", in: transcript)
            try EditorUISnapshot.check(try await renderer.render(transcript), named: "markdown-multicolumn-table")
        }

        @Test func filesAndImages() async throws {
            let renderer = try EditorUISnapshotRenderer()
            let directory = try fixtureDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let image = try makePreviewImage(in: directory)
            let file = directory.appendingPathComponent("Scene.ada")
            try "let player = Entity()\n".write(to: file, atomically: true, encoding: .utf8)
            let events = [
                message("request", role: .user, text: "Use this reference and inspect the scene.", extra: [
                    .init(kind: .attachment, attachment: .init(name: "Preview.png", mimeType: "image/png", sizeBytes: 1_250, absolutePath: image.path)),
                    .init(kind: .attachment, attachment: .init(name: "Scene.ada", mimeType: "text/plain", sizeBytes: 22, absolutePath: file.path)),
                    .init(kind: .skill, skill: .init(id: "scene-review", name: "Scene Review", localPath: "", userInvocable: true, allowedTools: [], instructions: "")),
                ]),
                message("reply", text: "The generated preview is attached.", extra: [
                    .init(kind: .attachment, attachment: .init(name: "Generated.png", mimeType: "image/png", sizeBytes: 1_250, absolutePath: image.path)),
                    .init(kind: .attachment, attachment: .init(
                        name: "Missing.png",
                        mimeType: "image/png",
                        absolutePath: directory.appendingPathComponent("Missing.png").path
                    )),
                ]),
            ]
            let transcript = await mount(events, width: 460, height: 370)
            try requireVisible("AdaEditor.Agent.Event.request", in: transcript)
            try requireVisible("AdaEditor.Agent.Event.reply", in: transcript)
            let screenshot = try await renderer.render(transcript)
            try requirePreviewPixels(in: screenshot)
            try EditorUISnapshot.check(screenshot, named: "files-and-images")
        }

        @Test func systemMessagesAndErrors() async throws {
            let renderer = try EditorUISnapshotRenderer()
            let events = [
                message("system", role: .system, text: "**System notice** · Workspace context refreshed."),
                message("tool-message", role: .tool, text: "Tool message: inspected the current scene."),
                .init(id: "interruption", kind: .error, title: "Interrupted", details: "The user stopped this run."),
                .init(id: "failure", kind: .error, title: "Agent failed", details: "The provider is temporarily unavailable."),
                message("provider-failure", text: #"{"type":"error","status":400,"error":{"message":"Please upgrade your agent."}}"#),
                .init(id: "done", kind: .runStatus, title: "Done", details: "end_turn"),
            ]
            let transcript = await mount(events, width: 460, height: 280)
            for id in ["system", "tool-message", "interruption", "failure", "provider-failure"] {
                try requireVisible("AdaEditor.Agent.Event.\(id)", in: transcript)
            }
            #expect(transcript.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Agent.Event.done")).isEmpty)
            try EditorUISnapshot.check(try await renderer.render(transcript), named: "system-and-errors")
        }

        @Test func toolActivity() async throws {
            let renderer = try EditorUISnapshotRenderer()
            let events = [
                message("task", role: .user, text: "Run the level checks and show the change."),
                message("thought", text: "I will inspect the scene first.", kind: .thinking),
                .init(id: "status", kind: .runStatus, title: "Preparing workspace", details: "Using local project files."),
                .init(id: "read", kind: .toolCall, title: "Read scene", toolCall: .init(
                    id: "read",
                    title: "Read scene",
                    kind: "read",
                    status: .inProgress,
                    content: [.init(kind: .text, text: "Reading **Assets/Main.ascn**…")],
                    locations: [.init(path: "Assets/Main.ascn", line: 12)]
                )),
                .init(id: "result", kind: .toolResult, title: "Check level", toolCall: .init(
                    id: "result",
                    title: "Check level",
                    kind: "execute",
                    status: .completed,
                    content: [
                        .init(kind: .diff, path: "Assets/Main.ascn", newText: "health: 100"),
                        .init(kind: .terminal, terminalID: "level-check"),
                        .init(kind: .image, mimeType: "image/png"),
                        .init(kind: .resource, uri: "res://Assets/Main.ascn"),
                    ],
                    locations: []
                )),
                permissionEvent("approved", state: .selected),
                permissionEvent("cancelled", state: .cancelled),
                message("result-reply", text: "The level checks passed."),
            ]
            let transcript = await mount(events, width: 460, height: 175)
            try requireVisible("AdaEditor.Agent.ToggleActions.actions:task", in: transcript)
            #expect(transcript.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Agent.Event.status")).isEmpty)
            try EditorUISnapshot.check(try await renderer.render(transcript), named: "actions-collapsed")

            transcript.frame.size.height = 810
            transcript.bounds.size = transcript.frame.size
            await settle(transcript)
            _ = try transcript.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.ToggleActions.actions:task"))
            await settle(transcript)
            for id in ["thought", "status", "read", "result"] {
                _ = try transcript.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.ToggleEvent.\(id)"))
                await settle(transcript)
            }
            for id in ["thought", "status", "read", "result", "approved", "cancelled", "result-reply"] {
                try requireVisible("AdaEditor.Agent.Event.\(id)", in: transcript)
            }
            try requireVisible("AdaEditor.Agent.Event.task", in: transcript)
            try requireVisible("AdaEditor.Agent.ToggleActions.actions:task", in: transcript)
            try EditorUISnapshot.check(try await renderer.render(transcript), named: "actions-expanded")
        }

        @Test func permissionRequest() async throws {
            let renderer = try EditorUISnapshotRenderer()
            let events = [
                message("task", role: .user, text: "Validate the current scene."),
                permissionEvent("waiting", state: .pending, inputDetails: "{\n  \"path\": \"Assets/Main.ascn\",\n  \"strict\": true\n}"),
            ]
            let transcript = await mount(events, width: 460, height: 335)
            try requireVisible("AdaEditor.Agent.Permission.waiting", in: transcript)
            try requireVisible("AdaEditor.Agent.LocalMCP.InputDetails", in: transcript)
            try EditorUISnapshot.check(try await renderer.render(transcript), named: "permission-request")
        }

        @Test(arguments: [false, true])
        func a2uiForm(cancelled: Bool) async throws {
            let renderer = try EditorUISnapshotRenderer()
            let directory = try fixtureDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = try makePreviewImage(in: directory)
            let settings = EditorAgentSettingsStore()
            try settings.save(.init(enabled: true, target: .init(command: "fixture-agent")))
            let model = EditorAgentViewModel(project: nil, settings: settings, service: FakeEditorAgentService(), notifications: EditorNotificationCenter())
            model.a2ui.resources = UISceneResources(rootURL: directory)
            let reply = message("form", text: Self.formReply)
            let session = EditorAgentSession(id: "a2ui-snapshot", events: [message("task", role: .user, text: "Preview a guide NPC.")])
            model.activeSession = session
            let ui = model.a2ui.restoreIfNeeded(session)
            ui.beginRun(agentIdentity: settings.configuration.target.sessionIdentity)
            ui.receive(reply)
            model.activeSession?.events.append(reply)
            try #require(ui.eventErrors.isEmpty)
            try #require(ui.records["npc-preview"]?.agentIdentity == settings.configuration.target.sessionIdentity)
            try #require(ui.records["npc-preview"]?.state == .receiving)
            let transcript = await mount(model: model, width: 460, height: 510)
            let action = "a2ui.npc-preview.generate"
            for id in ["AdaEditor.Agent.Event.task", "AdaEditor.Agent.A2UI.Surface.npc-preview", "a2ui.npc-preview.name", "a2ui.npc-preview.image", action] {
                try requireVisible(id, in: transcript)
            }
            #expect(transcriptLabels(in: transcript).contains("Preparing form…"))
            let receiving = try await renderer.render(transcript)
            try requirePreviewPixels(in: receiving)
            if !cancelled {
                try EditorUISnapshot.check(receiving, named: "a2ui-receiving")
            }

            ui.finishRun(cancelled: cancelled)
            await settle(transcript)
            try #require(ui.records["npc-preview"]?.state == (cancelled ? .cancelled : .ready))
            #expect(transcriptLabels(in: transcript).contains(cancelled ? "Interrupted" : "Ready"))
            try requireVisible("AdaEditor.Agent.A2UI.Surface.npc-preview", in: transcript)
            let finished = try await renderer.render(transcript)
            #expect(finished.data != receiving.data)
            try EditorUISnapshot.check(finished, named: cancelled ? "a2ui-interrupted" : "a2ui-ready")
        }

        @Test func streamedReply() async throws {
            let renderer = try EditorUISnapshotRenderer()
            let model = makeAgentModel()
            model.activeSession = .init(id: "stream-snapshot", events: [
                message("task", role: .user, text: "Summarize the level check."),
                message("reply", text: "Checking the level…"),
            ])
            let transcript = await mount(model: model, width: 460, height: 205)
            let reply = UINodeSelector.accessibilityIdentifier("AdaEditor.Agent.Event.reply")
            let first = try transcript.uiNode(matching: reply)
            let partial = try await renderer.render(transcript)
            try EditorUISnapshot.check(partial, named: "reply-streaming")

            let expandedReply = message("reply", text: "Checking the level…\n\n- **Scene:** Valid\n- **Assets:** 3 checked")
            try #require(model.a2ui.sessions["stream-snapshot"]).receive(expandedReply)
            model.activeSession?.events[1] = expandedReply
            await settle(transcript)
            let last = try transcript.uiNode(matching: reply)
            #expect(last.runtimeId == first.runtimeId)
            #expect(last.absoluteFrame.height > first.absoluteFrame.height)
            let finished = try await renderer.render(transcript)
            #expect(finished.data != partial.data)
            try EditorUISnapshot.check(finished, named: "reply-finished")
        }

        private static let formReply = "Configure the guide before generating a dialog.\n```a2ui\n" + [
            #"{"version":"v0.9.1","createSurface":{"surfaceId":"npc-preview","catalogId":"https://adaengine.org/a2ui/catalogs/forms/v1"}}"#,
            """
            {"version":"v0.9.1","updateComponents":{"surfaceId":"npc-preview","components":[
              {"id":"root","component":"Column","spacing":8,"children":["heading","image","name","repeatable","generate"]},
              {"id":"heading","component":"Text","text":"Guide preview"},
              {"id":"image","component":"Image","path":"Preview.png","zoom":3},
              {"id":"name","component":"TextField","text":{"path":"/name"},"placeholder":"Name"},
              {"id":"repeatable","component":"Toggle","label":"Repeatable dialog","value":{"path":"/repeatable"}},
              {"id":"generate","component":"Button","text":"Generate dialog","action":{"event":{"name":"generate"}}}
            ]}}
            """.replacingOccurrences(of: "\n", with: ""),
            #"{"version":"v0.9.1","updateDataModel":{"surfaceId":"npc-preview","value":{"name":"Ada Guide","repeatable":true}}}"#,
        ].joined(separator: "\n") + "\n```\n"

        private func message(
            _ id: String,
            role: EditorAgentRole = .assistant,
            text: String,
            kind: EditorAgentMessageSegmentKind = .text,
            extra: [EditorAgentMessageSegment] = []
        ) -> EditorAgentEvent {
            .init(id: id, kind: .message, message: .init(role: role, segments: [.init(kind: kind, text: text)] + extra))
        }

        private func permissionEvent(_ id: String, state: EditorAgentPermissionState, inputDetails: String? = nil) -> EditorAgentEvent {
            .init(id: id, kind: .permission, permission: .init(
                id: id,
                summary: state == .cancelled ? "Run the optional asset check" : "Allow Validate Scene to read the project?",
                options: [.init(id: "once", name: "Allow once", kind: "allow_once"), .init(id: "deny", name: "Deny", kind: "reject_once")],
                state: state,
                inputDetails: inputDetails
            ))
        }

        private func mount(_ events: [EditorAgentEvent], width: Float, height: Float) async -> UIContainerView<AnyView> {
            let model = makeAgentModel()
            model.activeSession = .init(id: "chat-snapshot", events: events)
            return await mount(model: model, width: width, height: height)
        }

        private func makeAgentModel() -> EditorAgentViewModel {
            EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService(), notifications: EditorNotificationCenter())
        }

        private func mount(model: EditorAgentViewModel, width: Float, height: Float) async -> UIContainerView<AnyView> {
            let view = EditorAgentTranscript(viewModel: model, compactMessages: true).theme(.adaEditor)
            let container = UIContainerView(rootView: AnyView(view))
            container.frame = Rect(x: 0, y: 0, width: width, height: height)
            container.bounds.size = container.frame.size
            await settle(container)
            return container
        }

        private func settle(_ container: UIContainerView<AnyView>) async {
            for _ in 0..<6 {
                await Task.yield()
                container.layoutIfNeeded()
                container.update(1 / 60)
            }
        }

        private func requireVisible(_ identifier: String, in container: UIContainerView<AnyView>) throws {
            let frame = try container.uiNode(matching: .accessibilityIdentifier(identifier)).absoluteFrame
            try #require(frame.height > 0 && frame.minY >= 0 && frame.maxY <= container.bounds.height + 0.5,
                         "\(identifier) must fit inside the captured viewport. Row: \(frame), viewport: \(container.bounds)")
        }

        private func transcriptLabels(in container: UIContainerView<AnyView>) -> [String] {
            container.viewTree.rootNode.uiCollectNodes { $0 is TextViewNode && $0.frame.height > 0 }
                .compactMap { ($0 as? TextViewNode)?.selectableText }
        }

        private func fixtureDirectory() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSnapshot-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private func makePreviewImage(in directory: URL) throws -> URL {
            var image = Image(width: 30, height: 20, color: .blue)
            for y in 4..<16 {
                for x in 5..<25 {
                    image.setPixel(in: [Float(x), Float(y)], color: x < 15 ? .green : .red)
                }
            }
            let url = directory.appendingPathComponent("Preview.png")
            try image.writePNG(to: url)
            return url
        }

        private func requirePreviewPixels(in image: Image) throws {
            let containsGreen = (0..<image.height).contains { y in
                (0..<image.width).contains { x in
                    let color = image.getPixel(x: x, y: y)
                    return color.green > 0.8 && color.red < 0.15 && color.blue < 0.15
                }
            }
            try #require(containsGreen, "The fixture texture must reach the real render target.")
        }
    }
#endif
