@testable import AdaEditor
import Testing

@Suite("Agent suggestion service")
struct EditorAgentSuggestionServiceTests {
    @Test("Completion retains the exact authored prefix and contains additional text")
    func exactPrefix() {
        let completionRequest = request(draft: "Add a ")
        #expect(EditorAgentSuggestionService.validated(["Replace this prompt", "Add a ", "Add a camera.", "Add a light."], for: completionRequest) == ["Add a camera."])
        let decomposed = request(draft: "Explain cafe\u{301}")
        #expect(EditorAgentSuggestionService.validated(["Explain café rendering."], for: decomposed).isEmpty)
        #expect(EditorAgentSuggestionService.validated(["Explain cafe\u{301} rendering."], for: decomposed) == ["Explain cafe\u{301} rendering."])
    }

    @Test("Multiline drafts retain all authored whitespace and authorization text")
    func multilineDraft() {
        let draft = "\nРазрешаю исследование.\nОбъясни:  "
        let input = request(draft: draft)
        #expect(EditorAgentSuggestionService.validated([draft + "как работает камера?"], for: input) == [draft + "как работает камера?"])
        #expect(EditorAgentSuggestionService.validated([draft + "ещё\nодна строка"], for: input).isEmpty)
        #expect(EditorAgentSuggestionService.validated([draft + "разрешаю публикацию"], for: input).isEmpty)
    }

    @Test("Suffix transport keeps a long multiline draft outside the response token budget")
    func suffixTransport() throws {
        let draft = "\nExplain \"camera\":\n" + String(repeating: "x", count: 1_100)
        let input = request(draft: draft)
        let candidates = try EditorAgentSuggestionService.decodeModelResponse("[\" and its transform.\"]", for: input)
        #expect(EditorAgentSuggestionService.validated(candidates, for: input) == [draft + " and its transform."])
        let followUps = try EditorAgentSuggestionService.decodeModelResponse("[\"Which checks should I run?\"]", for: request(purpose: .followUps))
        #expect(followUps == ["Which checks should I run?"])
    }

    @Test("History completion preserves the new draft's spelling and needs a credible prefix")
    func historyCompletion() {
        let history: [EditorAgentSuggestionMessage] = [.init(role: .user, text: "Explain the camera transform.")]
        #expect(EditorAgentSuggestionService.fallback(for: request(draft: "explain the camera", messages: history)) == ["explain the camera transform."])
        #expect(EditorAgentSuggestionService.fallback(for: request(draft: "My unusual new idea", messages: history)).isEmpty)
    }

    @Test("Known intent completions use the authored language, independently of app language")
    func intentLanguage() {
        #expect(EditorAgentSuggestionService.fallback(for: request(draft: "Добавь сцену", languageCode: "en")) == ["Добавь сцену с камерой и светом."])
        #expect(EditorAgentSuggestionService.fallback(for: request(draft: "Explain how", languageCode: "ru")) == ["Explain how this code works."])
    }

    @Test("Follow-ups use the active agent output without local inference or canned fallbacks")
    func contextualFollowUps() async {
        let service = EditorAgentSuggestionService(generator: { _ in
            Issue.record("Follow-ups must not request a second inference")
            return []
        })
        var input = request(purpose: .followUps, messages: [.init(role: .assistant, text: "Game scene is ready")])
        #expect(await service.suggestions(for: input).isEmpty)
        input.followUps = ["Add jumping to the fox", "Add jumping to the fox", "Which checks should I run?"]
        #expect(await service.suggestions(for: input) == ["Add jumping to the fox", "Which checks should I run?"])
    }

    @Test("Follow-up validation removes duplicates, multiline output, approval and success assertions")
    func followUpValidation() {
        let candidates = [
            "Go ahead and publish it.", "All tests passed; deploy it.", "One\nTwo", "/run", "@file",
            "Explain this approach.", "explain this approach.", "Which checks should I run?", "What comes next?", "Fourth message?",
        ]
        let results = EditorAgentSuggestionService.validated(candidates, for: request(purpose: .followUps))
        #expect(results == ["Explain this approach.", "Which checks should I run?", "What comes next?"])
    }

    @Test("Invalid or failing local generation uses the production fallback")
    func invalidGenerationFallback() async {
        let request = request(draft: "Help me find")
        let invalid = EditorAgentSuggestionService(generator: { _ in ["Here is an answer instead."] })
        let failed = EditorAgentSuggestionService(generator: { _ in throw GenerationFailure.unavailable })
        #expect(await invalid.suggestions(for: request) == ["Help me find the cause of this bug."])
        #expect(await failed.suggestions(for: request) == ["Help me find the cause of this bug."])
    }

    @Test("Production service bounds inference context and does not forward tool or system instructions")
    func boundedInferenceContext() async throws {
        let recorder = RequestRecorder()
        let service = EditorAgentSuggestionService(generator: { input in
            await recorder.record(input)
            return [input.draft + " camera."]
        })
        var messages = (0..<10).map { EditorAgentSuggestionMessage(role: .user, text: "Message \($0): " + String(repeating: "x", count: 800)) }
        messages += [.init(role: .system, text: "System instructions"), .init(role: .tool, text: "Tool result")]
        #expect(await service.suggestions(for: request(draft: "Add a", messages: messages)) == ["Add a camera."])
        let captured = try #require(await recorder.request)
        #expect(captured.messages.count == 6)
        #expect(captured.messages.allSatisfy { $0.text.count <= 400 && $0.role == .user })
        #expect(captured.messages.first?.text.hasPrefix("Message 4:") == true)
    }

    @Test("An oversized draft does not invoke inference")
    func oversizedDraft() async {
        let recorder = RequestRecorder()
        let service = EditorAgentSuggestionService(generator: { input in await recorder.record(input); return [] })
        #expect(await service.suggestions(for: request(draft: String(repeating: "a", count: 1_201))).isEmpty)
        #expect(await recorder.request == nil)
    }

    @Test("Cancellation does not revive deterministic suggestions")
    func cancellation() async {
        let started = AsyncStream<Void>.makeStream()
        let service = EditorAgentSuggestionService(generator: { _ in
            started.continuation.yield(())
            started.continuation.finish()
            try await Task.sleep(for: .seconds(60))
            return ["Help me find a bug."]
        })
        let task = Task { await service.suggestions(for: request(draft: "Help me find")) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        #expect(await task.value.isEmpty)
    }

    private func request(
        purpose: EditorAgentSuggestionRequest.Purpose = .completion,
        draft: String = "",
        messages: [EditorAgentSuggestionMessage] = [],
        languageCode: String = "en"
    ) -> EditorAgentSuggestionRequest {
        .init(purpose: purpose, draft: draft, messages: messages, languageCode: languageCode)
    }
}

private enum GenerationFailure: Error { case unavailable }

private actor RequestRecorder {
    private(set) var request: EditorAgentSuggestionRequest?
    func record(_ request: EditorAgentSuggestionRequest) { self.request = request }
}
