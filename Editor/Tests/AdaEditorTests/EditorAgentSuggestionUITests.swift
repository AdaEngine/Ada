@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Editor agent suggestion UI", .serialized)
@MainActor
struct EditorAgentSuggestionUITests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AgentSuggestionUI")))
        }
    }

    @Test("Suggestions highlight across the full row on hover and restore on leave", arguments: [false, true])
    func suggestionHover(completion: Bool) async throws {
        let service = FakeEditorAgentService()
        let model = makeModel(service: service)
        model.activeSession = completion ? EditorAgentSession(title: "Completion") : completedSession()
        model.prompt = completion ? "Explain" : ""
        model.panelDidAppear()
        defer { model.panelDidDisappear() }
        model.refreshPromptSuggestions()
        let container = UIContainerView(rootView: EditorAgentSuggestionsView(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 320, height: 400)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        try await waitForSuggestions(model, container: container)
        let original = model.prompt
        let suggestion = try #require(model.promptSuggestions.suggestions.first)
        let highlight = Theme.adaEditor.editorColors.text.opacity(0.10)
        func fillCount() -> Int {
            let context = UIGraphicsContext()
            container.draw(in: container.bounds, with: context)
            return context.getDrawCommands().filter { command in
                switch command {
                case let .drawPath(_, _, .fill(color)), let .drawQuad(_, _, color): color == highlight
                default: false
                }
            }.count
        }
        func move(to point: Point) async {
            container.onMouseEvent(MouseEvent(
                window: .empty, button: .none, mousePosition: point, phase: .changed, modifierKeys: [], time: 0
            ))
            await refresh(container)
        }
        await move(to: Point(2, 2))
        let normalCount = fillCount()
        let count = completion ? 1 : 3
        for index in 0..<count {
            let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Agent.PromptSuggestion.\(index)")
            let frame = try container.uiNode(matching: selector).absoluteFrame
            await move(to: Point(frame.maxX - 2, frame.midY))
            #expect(fillCount() == normalCount + 1)
            #expect(try container.uiNode(matching: selector).absoluteFrame == frame)
            #expect(model.prompt == original)
            await move(to: Point(2, 2))
            #expect(fillCount() == normalCount)
        }
        #expect(await service.recordedRequest() == nil)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.PromptSuggestion.0"))
        #expect(model.prompt == suggestion)
        #expect(await service.recordedRequest() == nil)
    }

    @Test("Typing shows a suggestion; tapping fills an editable draft without sending")
    func completionInsertion() async throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FakeEditorAgentService()
        let model = makeModel(root: root, service: service)
        await model.loadSessions()
        let container = makeContainer(model)
        try focusPrompt(container)
        container.onTextInputEvent(TextInputEvent(window: .empty, text: "Explain", action: .insert, time: 0))
        try await waitForSuggestions(model, container: container)
        #expect(model.promptSuggestions.suggestions.count == 1)
        let suggestion = try #require(model.promptSuggestions.suggestions.first)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.PromptSuggestion.0"))
        await refresh(container)
        #expect(model.prompt == suggestion)
        #expect(await service.recordedRequest() == nil)
        #expect(model.promptSuggestions.suggestions.isEmpty)

        // Re-enter the real composer: the inserted suggestion is ordinary editable text.
        try focusPrompt(container)
        container.onTextInputEvent(TextInputEvent(window: .empty, text: " please", action: .insert, time: 2))
        let authored = model.prompt
        #expect(authored.contains(" please"))
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .enter, modifiers: [], status: .down, time: 3, isRepeated: false))
        try await waitForRequest(service)
        #expect(await service.recordedRequest()?.prompt == authored)
    }

    @Test("Enter sends the authored draft while a natural completion is visible")
    func enterDoesNotAcceptNaturalCompletion() async throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FakeEditorAgentService()
        let model = makeModel(root: root, service: service)
        await model.loadSessions()
        let container = makeContainer(model)
        try focusPrompt(container)
        container.onTextInputEvent(TextInputEvent(window: .empty, text: "Explain", action: .insert, time: 0))
        try await waitForSuggestions(model, container: container)
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .enter, modifiers: [], status: .down, time: 1, isRepeated: false))
        try await waitForRequest(service)
        #expect(await service.recordedRequest()?.prompt == "Explain")
    }

    @Test("Successful answers show next-message chips, and dismissing keeps the draft empty")
    func followUpDismissal() async throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FakeEditorAgentService()
        let model = makeModel(root: root, service: service)
        await model.loadSessions()
        let container = makeContainer(model)
        try focusPrompt(container)
        container.onTextInputEvent(TextInputEvent(window: .empty, text: "Help", action: .insert, time: 0))
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .enter, modifiers: [], status: .down, time: 1, isRepeated: false))
        try await waitForSuggestions(model, container: container)
        #expect(model.promptSuggestions.purpose == .followUps)
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.PromptSuggestion.2"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agent.DismissPromptSuggestions"))
        await refresh(container)
        #expect(model.prompt.isEmpty)
        #expect(model.promptSuggestions.suggestions.isEmpty)
        #expect(throws: (any Error).self) {
            try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.PromptSuggestion.0"))
        }
        model.refreshPromptSuggestions()
        try await Task.sleep(for: .milliseconds(550))
        #expect(model.promptSuggestions.suggestions.isEmpty)
    }

    @Test("Escape dismisses natural completions through the prompt editor")
    func escapeDismissal() async throws {
        let model = makeModel()
        model.activeSession = EditorAgentSession(title: "Hints")
        let container = makeContainer(model)
        try focusPrompt(container)
        container.onTextInputEvent(TextInputEvent(window: .empty, text: "Explain", action: .insert, time: 0))
        try await waitForSuggestions(model, container: container)
        container.onKeyEvent(KeyEvent(window: .empty, keyCode: .escape, modifiers: [], status: .down, time: 1, isRepeated: false))
        await refresh(container)
        #expect(model.prompt == "Explain")
        #expect(model.promptSuggestions.suggestions.isEmpty)
    }

    @Test("Mounted hints refresh language and Russian text wraps in a narrow sidebar and workspace")
    func liveLanguageAndLayout() async throws {
        let previous = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previous }
        EditorLocalization.shared.preference = .english
        let model = makeModel()
        model.activeSession = completedSession()
        let container = makeContainer(model, width: 300)
        try await waitForSuggestions(model, container: container)
        let before = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.PromptSuggestion.0")).absoluteFrame
        EditorLocalization.shared.preference = .russian
        await refresh(container)
        for _ in 0..<150 {
            if model.promptSuggestions.suggestions.first == SuggestionUIService.russianFollowUp { break }
            try await Task.sleep(for: .milliseconds(10))
            await refresh(container)
        }
        #expect(model.promptSuggestions.suggestions.first == SuggestionUIService.russianFollowUp)
        let after = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.PromptSuggestion.0")).absoluteFrame
        #expect(after.minX >= 0 && after.maxX <= 300)
        #expect(after.height > before.height)
        let dismiss = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.DismissPromptSuggestions")).absoluteFrame
        #expect(dismiss.minX >= 0 && dismiss.maxX <= 300)

        let workspace = makeContainer(model, width: 1_200, presentation: .workspace)
        await refresh(workspace)
        let chip = try workspace.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.PromptSuggestion.0")).absoluteFrame
        let column = try workspace.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.ContentColumn")).absoluteFrame
        #expect(column.width == EditorAgentSidebar.maximumContentWidth)
        #expect(chip.minX >= column.minX && chip.maxX <= column.maxX)
    }

    @Test("Pointer caret moves and drag selection invalidate hints until the caret returns to the end")
    func pointerCaretInvalidation() async throws {
        let model = makeModel()
        model.activeSession = EditorAgentSession(title: "Pointer hints")
        let container = makeContainer(model)
        try focusPrompt(container)
        container.onTextInputEvent(TextInputEvent(window: .empty, text: "Explain", action: .insert, time: 0))
        try await waitForSuggestions(model, container: container)
        let stale = try #require(model.promptSuggestions.suggestions.first)

        func pointer(_ phase: MouseEvent.Phase, x: Float, time: Float) throws {
            let frame = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Prompt")).absoluteFrame
            container.onMouseEvent(MouseEvent(
                window: .empty, button: .left, mousePosition: Point(frame.minX + x, frame.minY + 15),
                phase: phase, modifierKeys: [], time: time
            ))
        }

        try pointer(.began, x: 25, time: 1)
        try pointer(.ended, x: 25, time: 1.1)
        await refresh(container)
        #expect(try #require(model.promptCaretOffset) < model.prompt.count)
        #expect(model.promptSuggestions.suggestions.isEmpty)
        model.insertPromptSuggestion(stale)
        #expect(model.prompt == "Explain")
        #expect(throws: (any Error).self) {
            try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.PromptSuggestion.0"))
        }

        try pointer(.began, x: 200, time: 2)
        try pointer(.ended, x: 200, time: 2.1)
        #expect(model.promptCaretOffset == model.prompt.count)
        try await waitForSuggestions(model, container: container)

        try pointer(.began, x: 200, time: 3)
        try pointer(.changed, x: 25, time: 3.1)
        try pointer(.ended, x: 25, time: 3.2)
        await refresh(container)
        #expect(try #require(model.promptCaretOffset) < model.prompt.count)
        #expect(model.promptSuggestions.suggestions.isEmpty)
        model.insertPromptSuggestion(stale)
        #expect(model.prompt == "Explain")

        try pointer(.began, x: 200, time: 4)
        try pointer(.ended, x: 200, time: 4.1)
        try await waitForSuggestions(model, container: container)
        #expect(model.promptCaretOffset == model.prompt.count)
    }

    private func makeModel(root: URL? = nil, service: FakeEditorAgentService = FakeEditorAgentService()) -> EditorAgentViewModel {
        EditorAgentViewModel(
            project: root.map { .init(name: "Suggestions", path: $0.path) },
            settings: EditorAgentSettingsStore(),
            service: service,
            suggestionService: SuggestionUIService()
        )
    }

    private func makeContainer(
        _ model: EditorAgentViewModel,
        width: Float = 560,
        presentation: EditorAgentChatPresentation = .sidebar
    ) -> UIContainerView<EditorAgentSidebar> {
        let container = UIContainerView(rootView: EditorAgentSidebar(viewModel: model, presentation: presentation))
        container.frame = Rect(x: 0, y: 0, width: width, height: 820)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        return container
    }

    private func focusPrompt(_ container: UIContainerView<EditorAgentSidebar>) throws {
        let frame = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agent.Prompt")).absoluteFrame
        for phase in [MouseEvent.Phase.began, .ended] {
            container.onMouseEvent(MouseEvent(
                window: .empty, button: .left, mousePosition: Point(frame.minX + 15, frame.minY + 15), phase: phase, modifierKeys: [], time: 0
            ))
        }
    }

    private func refresh<Content: View>(_ container: UIContainerView<Content>) async {
        for _ in 0..<10 {
            await Task.yield()
            container.update(1 / 60)
            container.layoutIfNeeded()
        }
    }

    private func waitForSuggestions<Content: View>(_ model: EditorAgentViewModel, container: UIContainerView<Content>) async throws {
        for _ in 0..<200 {
            if !model.promptSuggestions.suggestions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
            await refresh(container)
        }
        #expect(!model.promptSuggestions.suggestions.isEmpty)
        await refresh(container)
    }

    private func waitForRequest(_ service: FakeEditorAgentService) async throws {
        for _ in 0..<100 {
            if await service.recordedRequest() != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Composer did not send a request")
    }

    private func temporaryProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSuggestions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Suggestions"), at: root)
        return root
    }

    private func completedSession() -> EditorAgentSession {
        var session = EditorAgentSession(title: "Completed")
        session.events = [
            .init(kind: .message, message: .init(role: .user, segments: [.init(kind: .text, text: "Help")])),
            .init(kind: .message, message: .init(role: .assistant, segments: [.init(kind: .text, text: "Done")])),
            .init(kind: .runStatus, title: "Done", isSuccessful: true),
        ]
        return session
    }
}

private struct SuggestionUIService: EditorAgentSuggestionServing {
    static let russianFollowUp = "Покажи, как проверить изменения в этой сцене, и объясни, какие результаты помогут убедиться, что всё работает правильно."

    func suggestions(for request: EditorAgentSuggestionRequest) async -> [String] {
        if request.purpose == .completion { return [request.draft + " how this project works."] }
        return request.languageCode == "ru"
            ? [Self.russianFollowUp, "Объясни изменения.", "Предложи следующий шаг."]
            : ["Explain the changes.", "How can I verify this?", "Suggest the next step."]
    }
}
