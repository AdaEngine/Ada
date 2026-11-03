import Foundation
import Observation

/// Owns disposable composer hints; these never participate in keyboard submission.
@Observable
@MainActor
final class EditorAgentPromptSuggestions {
    struct Context: Equatable, Sendable {
        var sessionID: String
        var draft: String
        var caretOffset: Int
        var mode: String
        var languageCode: String
        var messages: [EditorAgentSuggestionMessage]
        var followUps: [String] = []
        var completedReplyID: String?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.sessionID == rhs.sessionID && lhs.draft.utf8.elementsEqual(rhs.draft.utf8)
                && lhs.caretOffset == rhs.caretOffset && lhs.mode == rhs.mode && lhs.languageCode == rhs.languageCode
                && lhs.messages == rhs.messages && lhs.followUps == rhs.followUps && lhs.completedReplyID == rhs.completedReplyID
        }
    }

    struct Snapshot: Equatable, Sendable {
        var context: Context
        var isVisible: Bool = true
        var isSending: Bool = false
        var hasStructuredCompletion: Bool = false

        var request: EditorAgentSuggestionRequest? {
            guard isVisible, !isSending, !hasStructuredCompletion else { return nil }
            let draft = context.draft
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if draft.isEmpty, context.completedReplyID != nil {
                return .init(purpose: .followUps, draft: draft, messages: context.messages, languageCode: context.languageCode, followUps: context.followUps)
            }
            guard trimmed.count >= 4, context.caretOffset == draft.count,
                  !trimmed.hasPrefix("/"), !trimmed.hasPrefix("@") else { return nil }
            return .init(purpose: .completion, draft: draft, messages: context.messages, languageCode: context.languageCode)
        }
    }

    private(set) var suggestions: [String] = []
    private(set) var purpose: EditorAgentSuggestionRequest.Purpose?
    @ObservationIgnored private let service: any EditorAgentSuggestionServing
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var snapshot: Snapshot?
    @ObservationIgnored private var dismissedContext: Context?

    init(service: any EditorAgentSuggestionServing, debounce: Duration = .milliseconds(475)) {
        self.service = service
        self.debounce = debounce
    }

    func update(_ snapshot: Snapshot?) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        invalidate()
        guard let snapshot, snapshot.context != dismissedContext, let request = snapshot.request else { return }
        let generation = generation
        let service = service
        let debounce = debounce
        task = Task { [weak self] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard !Task.isCancelled else { return }
            let candidates = await service.suggestions(for: request)
            guard !Task.isCancelled, let self, self.generation == generation, self.snapshot == snapshot else { return }
            var seen = Set<String>()
            let valid = candidates.filter { text in
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                if request.purpose == .completion,
                   !text.utf8.starts(with: request.draft.utf8) || text.count <= request.draft.count { return false }
                return seen.insert(text).inserted
            }
            self.suggestions = Array(valid.prefix(request.purpose == .completion ? 1 : 3))
            self.purpose = self.suggestions.isEmpty ? nil : request.purpose
            self.task = nil
        }
    }

    func dismiss() {
        dismissedContext = snapshot?.context
        invalidate()
    }

    /// Validate against the current snapshot again at acceptance, including authored prefix.
    func canInsert(_ text: String) -> Bool {
        guard let request = snapshot?.request, suggestions.contains(where: { $0.utf8.elementsEqual(text.utf8) }) else { return false }
        return request.purpose != .completion || (text.utf8.starts(with: request.draft.utf8) && text.count > request.draft.count)
    }

    private func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        suggestions = []
        purpose = nil
    }
}
