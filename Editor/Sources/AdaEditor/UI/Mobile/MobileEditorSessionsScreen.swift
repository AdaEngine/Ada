#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import Foundation
import SloppyRuntime

struct MobileEditorSessionSummary: Identifiable, Sendable {
    let id: String
    let title: String
    let updatedAt: Date
    let messageCount: Int
    let preview: String
}

actor MobileEditorSessionStore {
    let workspaceURL: URL

    init(workspaceURL: URL) { self.workspaceURL = workspaceURL }

    private var agentsURL: URL { workspaceURL.appendingPathComponent(".ada/workspace/agents", isDirectory: true) }

    func list() throws -> [MobileEditorSessionSummary] {
        guard FileManager.default.fileExists(atPath: agentsURL.appendingPathComponent("mobile").path) else { return [] }
        return try AgentSessionFileStore(agentsRootURL: agentsURL).listSessions(agentID: "mobile").map {
            MobileEditorSessionSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt, messageCount: $0.messageCount, preview: $0.lastMessagePreview ?? "")
        }
    }

    func messages(id: String) throws -> [SloppyChatMessage] {
        let detail = try AgentSessionFileStore(agentsRootURL: agentsURL).loadSession(agentID: "mobile", sessionID: id)
        return detail.events.compactMap { event in
            guard let message = event.message else { return nil }
            let role: SloppyChatMessage.Role
            switch message.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: return nil
            }
            let text = message.segments.compactMap(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return SloppyChatMessage(id: event.id, role: role, text: text, createdAt: event.createdAt)
        }
    }
}

struct MobileEditorSessionsScreen: View {
    @Environment(\.theme) private var theme
    @State private var sessions: [MobileEditorSessionSummary] = []
    @State private var status = "Loading sessions…"
    @State private var loadTask: Task<Void, Never>?
    let workspaceURL: URL
    let open: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !status.isEmpty {
                    Text(status).font(MobileEditorFont.font(size: 14)).foregroundColor(theme.editorColors.muted)
                }
                ForEach(sessions) { session in
                    Button { open(session.id) } label: {
                        MobileEditorCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(session.title).font(MobileEditorFont.font(size: 17)).foregroundColor(theme.editorColors.text)
                                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened) + " · \(session.messageCount) messages")
                                    .font(MobileEditorFont.font(size: 11)).foregroundColor(theme.editorColors.muted)
                                Text(session.preview).font(MobileEditorFont.font(size: 13)).foregroundColor(theme.editorColors.muted).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(17)
                        }
                    }
                    .accessibilityIdentifier("AdaEditor.Mobile.Session.\(session.id)")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
        }
        .background(theme.editorColors.background)
        .onAppear {
            loadTask = Task { @MainActor in
                do {
                    let loaded = try await MobileEditorSessionStore(workspaceURL: workspaceURL).list()
                    try Task.checkCancellation()
                    sessions = loaded
                    status = loaded.isEmpty ? "No sessions yet. Your conversations will appear here after the first request." : ""
                } catch { if !Task.isCancelled { status = error.localizedDescription } }
            }
        }
        .onDisappear { loadTask?.cancel() }
    }
}

struct MobileEditorSessionDetailScreen: View {
    @Environment(\.theme) private var theme
    @State private var events: [EditorAgentEvent] = []
    @State private var status = "Loading conversation…"
    @State private var loadTask: Task<Void, Never>?
    let workspaceURL: URL
    let sessionID: String

    var body: some View {
        VStack {
            if !status.isEmpty {
                Text(status).font(MobileEditorFont.font(size: 14)).foregroundColor(theme.editorColors.muted).padding(22)
            }
            EditorAgentTranscript(events: events, sessionID: sessionID)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.editorColors.background)
        .onAppear {
            loadTask = Task { @MainActor in
                do {
                    let messages = try await MobileEditorSessionStore(workspaceURL: workspaceURL).messages(id: sessionID)
                    try Task.checkCancellation()
                    events = MobileSloppyChatAdapter.events(from: messages)
                    status = messages.isEmpty ? "This session has no messages." : ""
                } catch { if !Task.isCancelled { status = error.localizedDescription } }
            }
        }
        .onDisappear { loadTask?.cancel() }
    }
}
#endif
