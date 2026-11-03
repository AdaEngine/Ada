@_spi(AdaEngine) import AdaEngine
import Math
import Observation

enum EditorAgentTranscriptEntry: Identifiable, Equatable {
    case event(EditorAgentEvent)
    case actions(id: String, events: [EditorAgentEvent])

    var id: String {
        switch self {
        case let .event(event): event.id
        case let .actions(id, _): id
        }
    }

    /// Put one action disclosure before the replies in each user turn.
    static func grouped(_ events: [EditorAgentEvent]) -> [Self] {
        var entries: [Self] = []
        var turnID = "initial"
        var actions: [EditorAgentEvent] = []
        var visible: [Self] = []

        func flushTurn() {
            if !actions.isEmpty {
                entries.append(.actions(id: "actions:\(turnID)", events: actions))
            }
            entries.append(contentsOf: visible)
            actions.removeAll()
            visible.removeAll()
        }

        for event in events {
            if event.message?.role == .user {
                flushTurn()
                entries.append(.event(event))
                turnID = event.id
                continue
            }

            if let message = event.message, message.role == .assistant {
                let thoughts = message.segments.filter { $0.kind == .thinking }
                if !thoughts.isEmpty {
                    var thoughtEvent = event
                    if thoughts.count != message.segments.count {
                        thoughtEvent.id += ":thinking"
                    }
                    thoughtEvent.message?.segments = thoughts
                    actions.append(thoughtEvent)
                    let replySegments = message.segments.filter { $0.kind != .thinking }
                    if !replySegments.isEmpty {
                        var replyEvent = event
                        replyEvent.message?.segments = replySegments
                        visible.append(.event(replyEvent))
                    }
                    continue
                }
            }

            let isAction =
                event.kind == .runStatus || event.toolCall != nil
                || (event.permission != nil && event.permission?.state != .pending)
            if isAction && event.kind != .error && event.permission?.state != .pending {
                if event.kind != .runStatus || event.title != "Done" {
                    actions.append(event)
                }
            } else {
                visible.append(.event(event))
            }
        }
        flushTurn()
        return entries
    }
}

@MainActor @Observable
final class EditorAgentTranscriptRow: Identifiable {
    let id: String
    var entry: EditorAgentTranscriptEntry

    init(_ entry: EditorAgentTranscriptEntry) {
        id = entry.id
        self.entry = entry
    }
}

/// Topology changes rebuild the list; streamed content updates only its owning row.
@MainActor @Observable
final class EditorAgentTranscriptState {
    private(set) var rows: [EditorAgentTranscriptRow] = []
    private(set) var revision: UInt64 = 0
    private(set) var sessionID: String?
    private(set) var userID: String?

    func update(events: [EditorAgentEvent], sessionID: String?) {
        let entries = EditorAgentTranscriptEntry.grouped(events)
        let sameSession = self.sessionID == sessionID
        let existing = sameSession ? Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }) : [:]
        let updated = entries.map { entry in
            if let row = existing[entry.id] {
                if row.entry != entry { row.entry = entry }
                return row
            }
            return EditorAgentTranscriptRow(entry)
        }
        if !sameSession || rows.map(\.id) != updated.map(\.id) { rows = updated }
        self.sessionID = sessionID
        userID = events.last { $0.message?.role == .user }?.id
        revision &+= 1
    }
}

private struct EditorAgentTranscriptRows: View {
    let state: EditorAgentTranscriptState
    let viewModel: EditorAgentViewModel?
    let a2uiPresentation: EditorAgentA2UIPresentation?

    var body: some View {
        ForEach(state.rows) { row in
            EditorAgentTranscriptRowView(row: row, viewModel: viewModel, a2uiPresentation: a2uiPresentation)
        }
    }
}

private struct EditorAgentTranscriptRowView: View {
    let row: EditorAgentTranscriptRow
    let viewModel: EditorAgentViewModel?
    let a2uiPresentation: EditorAgentA2UIPresentation?

    var body: some View {
        switch row.entry {
        case let .event(event):
            EditorAgentEventCard(event: event, viewModel: viewModel, a2uiPresentation: a2uiPresentation)
        case let .actions(id, events):
            EditorAgentActionsDisclosure(id: id, events: events, viewModel: viewModel, a2uiPresentation: a2uiPresentation)
        }
    }
}

struct EditorAgentActionsDisclosure: View {
    let id: String
    let events: [EditorAgentEvent]
    let viewModel: EditorAgentViewModel?
    var a2uiPresentation: EditorAgentA2UIPresentation?
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
                    Text(L10n.text("Actions · \(events.count)"))
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
                    EditorAgentEventCard(event: event, viewModel: viewModel, a2uiPresentation: a2uiPresentation)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("AdaEditor.Agent.Actions.\(id)")
    }
}

struct EditorAgentTranscript: View {
    let viewModel: EditorAgentViewModel?
    let standaloneEvents: [EditorAgentEvent]?
    let standaloneSessionID: String?
    @State private var follower = EditorAgentTranscriptFollower()
    @State private var standaloneState = EditorAgentTranscriptState()
    static let bottomID = "AdaEditor.Agent.Transcript.Bottom"

    init(viewModel: EditorAgentViewModel) {
        self.viewModel = viewModel
        self.standaloneEvents = nil
        self.standaloneSessionID = nil
    }

    init(events: [EditorAgentEvent], sessionID: String) {
        self.viewModel = nil
        self.standaloneEvents = events
        self.standaloneSessionID = sessionID
        standaloneState.update(events: events, sessionID: sessionID)
    }

    var a2uiPresentation: EditorAgentA2UIPresentation?
    var contentInsets = EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    var scrollContentInsets: EdgeInsets?
    var scrollRespectsSafeArea = true
    var scrollExtendsUnderNavigationBar = false

    var body: some View {
        let state = viewModel?.transcript ?? standaloneState
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(
                    .vertical,
                    showsIndicators: true,
                    contentInsets: scrollContentInsets,
                    respectsSafeArea: scrollRespectsSafeArea,
                    extendsUnderNavigationBar: scrollExtendsUnderNavigationBar
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        EditorAgentTranscriptRows(state: state, viewModel: viewModel, a2uiPresentation: a2uiPresentation)
                        Color.clear.frame(height: contentInsets.bottom + 1)
                            .id(Self.bottomID)
                            .accessibilityIdentifier(Self.bottomID)
                    }
                    .frame(width: max(0, geometry.size.width - contentInsets.leading - contentInsets.trailing), alignment: .leading)
                    .padding(EdgeInsets(top: contentInsets.top, leading: contentInsets.leading, bottom: 0, trailing: contentInsets.trailing))
                    .background {
                        GeometryReader { contentGeometry in
                            Color.clear.onChange(of: contentGeometry.size) { _, _ in
                                // A row can finish reconciling after the model revision was sampled.
                                // Follow again when its actual laid-out size becomes available.
                                follower.request(proxy, force: false)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("AdaEditor.Agent.Transcript")
                .background { EditorAgentTranscriptScrollDriver(follower: follower, state: state, proxy: proxy).allowsHitTesting(false) }
                .onAppear {
                    if let standaloneEvents { state.update(events: standaloneEvents, sessionID: standaloneSessionID) }
                    follower.appear(proxy)
                }
                .onChange(of: standaloneEvents) { _, events in
                    if let events { state.update(events: events, sessionID: standaloneSessionID) }
                }
                .onChange(of: standaloneSessionID) { _, sessionID in
                    if let standaloneEvents { state.update(events: standaloneEvents, sessionID: sessionID) }
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
    let state: EditorAgentTranscriptState
    let proxy: ScrollViewProxy
    func makeUIView(in _: Context) -> EditorAgentTranscriptScrollView { EditorAgentTranscriptScrollView() }
    func updateUIView(_ view: EditorAgentTranscriptScrollView, in _: Context) {
        view.follower = follower
        view.state = state
        view.proxy = proxy
        view.backgroundColor = .clear
        view.isInteractionEnabled = false
    }
    func sizeThatFits(_ proposal: ProposedViewSize, view _: EditorAgentTranscriptScrollView, context _: Context) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }
}

private final class EditorAgentTranscriptScrollView: UIView {
    var follower: EditorAgentTranscriptFollower?
    var state: EditorAgentTranscriptState?
    var proxy: ScrollViewProxy?
    var revision: UInt64?
    var sessionID: String?
    var userID: String?
    override func update(_: Float) {
        if let state, let proxy, revision != state.revision {
            follower?.request(proxy, force: sessionID != state.sessionID || userID != state.userID)
            revision = state.revision
            sessionID = state.sessionID
            userID = state.userID
        }
        follower?.flush()
    }
}
