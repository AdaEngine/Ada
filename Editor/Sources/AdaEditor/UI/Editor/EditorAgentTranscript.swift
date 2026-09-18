@_spi(AdaEngine) import AdaEngine
import Math

enum EditorAgentTranscriptEntry: Identifiable {
    case event(EditorAgentEvent)
    case actions(id: String, events: [EditorAgentEvent])

    var id: String {
        switch self {
        case let .event(event): event.id
        case let .actions(id, _): id
        }
    }

    /// One action disclosure per user turn. Replies, errors and pending approvals stay visible.
    static func grouped(_ events: [EditorAgentEvent]) -> [Self] {
        var entries: [Self] = []
        var actionsByID: [String: [EditorAgentEvent]] = [:]
        var turnID = "initial"
        var groupIndex: Int?
        for event in events {
            if event.message?.role == .user {
                turnID = event.id
                groupIndex = nil
            }
            let isThinking = event.message.map { !$0.segments.isEmpty && $0.segments.allSatisfy { $0.kind == .thinking } } ?? false
            let isAction =
                event.kind == .runStatus || event.toolCall != nil || isThinking
                || (event.permission != nil && event.permission?.state != .pending)
            if isAction && event.kind != .error && event.permission?.state != .pending {
                if let groupIndex {
                    actionsByID[entries[groupIndex].id, default: []].append(event)
                } else {
                    groupIndex = entries.count
                    let id = "actions:\(turnID)"
                    actionsByID[id] = [event]
                    entries.append(.actions(id: id, events: []))
                }
            } else {
                entries.append(.event(event))
            }
        }
        return entries.map { entry in
            if case let .actions(id, _) = entry {
                return .actions(id: id, events: actionsByID[id] ?? [])
            }
            return entry
        }
    }
}

struct EditorAgentActionsDisclosure: View {
    let id: String
    let events: [EditorAgentEvent]
    let viewModel: EditorAgentViewModel
    @State private var isExpanded = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(isExpanded ? "\u{E5CF}" : "\u{E5CC}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 16))
                    Text("Actions · \(events.filter { $0.toolCall != nil }.count)")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let title = events.last?.title {
                        Text(title).font(.system(size: 11)).lineLimit(1)
                    }
                }
                .foregroundColor(theme.editorColors.muted)
                .frame(height: 30)
                .padding(.horizontal, 8)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.Agent.ToggleActions.\(id)")
            if isExpanded {
                ForEach(events, id: \.id) { event in
                    EditorAgentEventCard(event: event, viewModel: viewModel)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("AdaEditor.Agent.Actions.\(id)")
    }
}

struct EditorAgentTranscript: View {
    let viewModel: EditorAgentViewModel
    @State private var follower = EditorAgentTranscriptFollower()
    static let bottomID = "AdaEditor.Agent.Transcript.Bottom"

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(EditorAgentTranscriptEntry.grouped(viewModel.activeSession?.events ?? [])) { entry in
                            switch entry {
                            case let .event(event):
                                EditorAgentEventCard(event: event, viewModel: viewModel)
                            case let .actions(id, events):
                                EditorAgentActionsDisclosure(id: id, events: events, viewModel: viewModel)
                            }
                        }
                        Color.clear.frame(height: 1)
                            .id(Self.bottomID)
                            .accessibilityIdentifier(Self.bottomID)
                    }
                    .frame(width: max(0, geometry.size.width - 20), alignment: .leading)
                    .padding(10)
                }
                .accessibilityIdentifier("AdaEditor.Agent.Transcript")
                .background { EditorAgentTranscriptScrollDriver(follower: follower).allowsHitTesting(false) }
                .onAppear { follower.appear(proxy) }
                .onChange(of: viewModel.activeSession?.id) { _, _ in follower.request(proxy, force: true) }
                .onChange(of: viewModel.activeSession?.events) { old, new in
                    let oldUser = old?.last { $0.message?.role == .user }?.id
                    let newUser = new?.last { $0.message?.role == .user }?.id
                    follower.request(proxy, force: oldUser != newUser)
                }
            }
        }
    }
}

/// Capture the reading position before relayout, then scroll after the new geometry exists.
@MainActor
private final class EditorAgentTranscriptFollower {
    private var pending: ScrollViewProxy?
    private var proxy: ScrollViewProxy?
    private var followsBottom = true
    private var hasAppeared = false

    func appear(_ proxy: ScrollViewProxy) {
        guard !hasAppeared else {
            return
        }
        hasAppeared = true
        request(proxy, force: true)
    }

    func request(_ proxy: ScrollViewProxy, force: Bool) {
        self.proxy = proxy
        // During view reconciliation the proxy can also contain temporary, unlaid-out nodes.
        // Use the reading position sampled on the last completed UI update instead.
        if force || followsBottom {
            pending = proxy
        }
    }

    func flush() {
        if let pending {
            self.pending = nil
            pending.scrollTo(EditorAgentTranscript.bottomID, anchor: .bottom)
        }
        followsBottom = proxy?.isNearBottom() ?? true
    }
}

private struct EditorAgentTranscriptScrollDriver: UIViewRepresentable {
    let follower: EditorAgentTranscriptFollower
    func makeUIView(in _: Context) -> EditorAgentTranscriptScrollView { EditorAgentTranscriptScrollView() }
    func updateUIView(_ view: EditorAgentTranscriptScrollView, in _: Context) {
        view.follower = follower
        view.backgroundColor = .clear
        view.isInteractionEnabled = false
    }
    func sizeThatFits(_ proposal: ProposedViewSize, view _: EditorAgentTranscriptScrollView, context _: Context) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }
}

private final class EditorAgentTranscriptScrollView: UIView {
    var follower: EditorAgentTranscriptFollower?
    override func update(_: Float) { follower?.flush() }
}
