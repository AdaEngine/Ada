@testable import AdaEditor
import Foundation
import Testing

@Suite("Agent authored next steps")
struct EditorAgentNextStepsTests {
    @Test func fragmentedReplyHidesMetadata() {
        let source = "Movement added.\n```ada-next\n[\"Добавь лисичке прыжок\",\"Добавь звук шагов\"]\n```"
        var stream = EditorAgentA2UIStream()
        for character in source {
            #expect(stream.append(String(character)).isEmpty)
            #expect(!stream.displayText.contains("ada-next"))
            #expect(!stream.displayText.contains("Добавь"))
        }
        #expect(stream.finish().isEmpty)
        #expect(stream.displayText == "Movement added.\n")
        #expect(stream.nextSteps == ["Добавь лисичке прыжок", "Добавь звук шагов"])
        #expect(!stream.didPresentUI)
    }

    @Test func malformedAndUnclosedBlocksDoNotOfferHints() {
        for block in ["[\"Jump\"]", "not JSON\n```", "[1]\n```", String(repeating: "x", count: 9_000) + "\n```"] {
            var stream = EditorAgentA2UIStream()
            _ = stream.append("Answer\n```ada-next\n" + block)
            _ = stream.finish()
            #expect(stream.nextSteps.isEmpty)
            #expect(stream.displayText == "Answer\n")
        }
    }

    @Test func ordinaryCodeAndA2UIKeepTheirMeaning() {
        let ordinary = "````markdown\n```ada-next\n[\"example\"]\n```\n````\n"
        var stream = EditorAgentA2UIStream()
        _ = stream.append(ordinary)
        _ = stream.finish()
        #expect(stream.displayText == ordinary)
        #expect(stream.nextSteps.isEmpty)
        var ui = EditorAgentA2UIStream()
        let frames = ui.append("```a2ui\n{}\n```\n```ada-next\n[\"Jump\"]\n```\n")
        #expect(frames.count == 1)
        #expect(ui.nextSteps == ["Jump"])
        #expect(ui.didPresentUI)
    }

    @Test @MainActor func persistedHintsReachComposerAndStayWithTheirTurn() async throws {
        let user = EditorAgentEvent(kind: .message, message: .init(role: .user, segments: [.init(kind: .text, text: "Make the fox move")]))
        let assistant = EditorAgentEvent(kind: .message, message: .init(role: .assistant, segments: [
            .init(kind: .text, text: "Movement added.\n```ada-next\n[\"Add jumping to the fox\"]\n```"),
        ]))
        let session = EditorAgentSession(events: [user, assistant, .init(kind: .runStatus, title: "Done")])
        let restored = try JSONDecoder().decode(EditorAgentSession.self, from: JSONEncoder().encode(session))
        #expect(EditorAgentNextSteps.candidates(in: restored) == ["Add jumping to the fox"])
        let ui = EditorAgentA2UISession(session: restored)
        #expect(ui.displayText(for: assistant.id) == "Movement added.\n")
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService())
        model.activeSession = restored
        model.panelDidAppear()
        for _ in 0..<100 where model.promptSuggestions.suggestions.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.promptSuggestions.suggestions == ["Add jumping to the fox"])
        model.insertPromptSuggestion("Add jumping to the fox")
        #expect(model.prompt == "Add jumping to the fox")
        #expect(!model.isSending)
        #expect(model.activeSession?.events.count == 3)
        var nextTurn = restored
        nextTurn.events.append(user)
        #expect(EditorAgentNextSteps.candidates(in: nextTurn).isEmpty)
        model.panelDidDisappear()
    }
}
