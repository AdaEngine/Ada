@_spi(AdaEngine) import AdaEngine

/// Place the draft above empty history or below populated history without moving its view node.
struct EditorAgentConversationLayout: Layout {
    static let footerHeight: Float = 34

    let isDocked: Bool

    func sizeThatFits(_ proposal: ProposedViewSize, subviews _: Subviews, cache _: inout Void) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: Rect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        guard subviews.count == 3 else {
            return
        }
        let footer = min(bounds.height, Self.footerHeight)
        let available = max(0, bounds.height - footer)
        var draftProposal = ProposedViewSize.unspecified
        draftProposal.width = bounds.width
        let draft = min(available, subviews[1].sizeThatFits(draftProposal).height)
        let transcript = available - draft

        func proposal(height: Float) -> ProposedViewSize {
            var result = draftProposal
            result.height = height
            return result
        }
        subviews[0].place(
            at: Point(bounds.minX, bounds.minY + (isDocked ? 0 : draft)),
            anchor: .topLeading,
            proposal: proposal(height: transcript)
        )
        subviews[1].place(
            at: Point(bounds.minX, bounds.minY + (isDocked ? transcript : 0)),
            anchor: .topLeading,
            proposal: proposal(height: draft)
        )
        subviews[2].place(
            at: Point(bounds.minX, bounds.minY + available),
            anchor: .topLeading,
            proposal: proposal(height: footer)
        )
    }
}

struct EditorAgentConversationHeader: View {
    let model: EditorAgentViewModel
    let showsHistory: Bool
    let onOpenCatalog: (() -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text("\u{E65F}")
                .font(AdaEditorMaterialSymbolFont.font(size: 14))
                .foregroundColor(theme.editorColors.blue)
            Text(model.activeSessionTitle ?? L10n.text("New session"))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if model.currentConnectionState == .connecting || model.isConnectingCatalogAgent {
                EditorFlipLoadingIndicator(size: 12, color: theme.editorColors.blue)
                    .accessibilityIdentifier("AdaEditor.Agent.ConnectionFlip")
            }
            if let status {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if showsHistory, !model.sessions.isEmpty {
                history
            }
            if case .failed = model.currentConnectionState {
                Button(L10n.text("Retry"), action: model.connect)
                    .font(.system(size: 11))
                    .padding(.horizontal, 4)
                    .frame(height: 26)
                    .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
                    .disabled(model.isSending)
                    .accessibilityIdentifier("AdaEditor.Agent.Retry")
            }
            headerButton("\u{E145}", title: "New Session", identifier: "AdaEditor.Agent.NewSession") {
                Task {
                    do {
                        try await model.createSession()
                    } catch {
                        model.statusMessage = error.localizedDescription
                    }
                }
            }
            if let onOpenCatalog {
                headerButton("\u{E8B8}", title: "Agent Settings", identifier: "AdaEditor.Agent.OpenCatalog", action: onOpenCatalog)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: AdaEngineStyleLayoutSpec.workspaceHeaderHeight)
        .modifier(EditorWorkspaceHeader())
        .accessibilityIdentifier("AdaEditor.Agent.Header")
    }

    private var history: some View {
        headerButton("\u{E8B5}", title: "Session history", identifier: "AdaEditor.Agent.SessionHistory.Button") {}
            .contextMenu(opensOnPrimaryAction: true) {
                ForEach(model.sessions, id: \.id) { session in
                    ContextMenuOption(historyTitle(session), isSelected: session.id == model.activeSessionID) {
                        model.selectSession(session)
                    }
                }
                Divider()
                ContextMenuSubmenu(L10n.text("Delete session")) {
                    ForEach(model.sessions, id: \.id) { session in
                        Button(historyTitle(session)) { model.deleteSession(session) }
                    }
                }
            }
            .accessibilityIdentifier("AdaEditor.Agent.SessionHistory")
    }

    private func historyTitle(_ session: EditorAgentSessionSummary) -> String {
        guard model.sessions.contains(where: { $0.id != session.id && $0.title == session.title }) else {
            return session.title
        }
        return "\(session.title) · \(session.updatedAt.formatted(date: .abbreviated, time: .shortened)) · \(session.id.prefix(8))"
    }

    private var status: String? {
        if model.isSending {
            return model.runningSessionID == model.activeSessionID ? L10n.text("Working") : L10n.text("Another session is running")
        }
        if model.isConnectingCatalogAgent {
            return L10n.text("Connecting")
        }
        switch model.currentConnectionState {
        case .ready, .running: return nil
        default: return model.settings.configuration.enabled ? L10n.tr(model.currentConnectionState.title) : L10n.text("Choose an agent")
        }
    }

    private func headerButton(_ symbol: String, title: String, identifier: String, action: @escaping () -> Void) -> some View {
        EditorSceneToolbarButton(title: title, symbol: symbol, identifier: identifier, compact: true, action: action)
    }
}

struct EditorAgentDraftChip: View {
    let title: String
    let symbol: String
    let onRemove: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text(symbol)
                .font(AdaEditorMaterialSymbolFont.font(size: 13))
                .foregroundColor(theme.editorColors.blue)
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            Button(action: onRemove) {
                Text("\u{E5CD}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 12))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
            .accessibilityIdentifier("AdaEditor.Agent.RemoveContext.\(title)")
        }
        .foregroundColor(theme.editorColors.text)
        .padding(.leading, 6)
        .background(RoundedRectangleShape(cornerRadius: 3).fill(theme.editorColors.surface))
        .overlay { adaEditorPanelBorder(theme: theme, cornerRadius: 3) }
    }
}

enum EditorAgentCompletionLayout {
    static func frame(caret: Rect, panel: Rect, entryCount: Int) -> Rect {
        let width = min(350, max(0, panel.width - 16))
        let left: Float = 8
        let top: Float = 4
        let bottom = max(top, panel.height - EditorAgentConversationLayout.footerHeight - 4)
        let preferredHeight = min(224, 30 + Float(entryCount) * 34)
        let caretTop = min(bottom, max(top, caret.minY - panel.minY))
        let caretBottom = min(bottom, max(top, caret.maxY - panel.minY))
        let above = max(0, caretTop - top - 4)
        let below = max(0, bottom - caretBottom - 4)
        let opensBelow = below >= preferredHeight || below >= above
        let height = min(preferredHeight, opensBelow ? below : above)
        let y = opensBelow ? caretBottom + 4 : caretTop - 4 - height
        let x = min(max(left, panel.width - width - left), max(left, caret.minX - panel.minX))
        return Rect(x: x, y: y, width: width, height: height >= 56 ? height : 0)
    }
}

struct EditorAgentCompletionList: View {
    let model: EditorAgentViewModel
    let compact: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if compact {
                Text(heading)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.editorColors.muted)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.autocompleteSuggestions.enumerated()), id: \.element.id) { index, entry in
                            row(entry, selected: index == model.selectedCompletionIndex)
                                .id(entry.id)
                        }
                    }
                }
                .onChange(of: model.selectedCompletionIndex) { _, index in
                    if model.autocompleteSuggestions.indices.contains(index) {
                        proxy.scrollTo(model.autocompleteSuggestions[index].id)
                    }
                }
            }
        }
        .padding(compact ? 4 : 6)
        .background(RoundedRectangleShape(cornerRadius: compact ? 5 : 8).fill(compact ? theme.editorColors.surface : theme.editorColors.background))
        .overlay { adaEditorPanelBorder(theme: theme, cornerRadius: compact ? 5 : 8) }
        .accessibilityIdentifier("AdaEditor.Agent.Completions")
    }

    private var heading: String {
        if case .file? = model.autocompleteSuggestions.first {
            return L10n.text("Context")
        }
        return L10n.text("Commands and skills")
    }

    private func row(_ entry: EditorAgentCompletion, selected: Bool) -> some View {
        Button(action: { model.insertAutocomplete(entry, attachingFile: compact) }) {
            HStack(spacing: compact ? 5 : 10) {
                Text(icon(for: entry))
                    .font(AdaEditorMaterialSymbolFont.font(size: compact ? 14 : 20))
                    .foregroundColor(theme.editorColors.blue)
                    .frame(width: compact ? 20 : 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.system(size: compact ? 12 : 13)).lineLimit(1)
                    if let detail = entry.detail, !detail.isEmpty {
                        Text(L10n.tr(detail))
                            .font(.system(size: compact ? 10 : 11))
                            .foregroundColor(theme.editorColors.muted)
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .foregroundColor(theme.editorColors.text)
            .padding(.horizontal, compact ? 4 : 10)
            .frame(height: compact ? 32 : 50)
            .background(RoundedRectangleShape(cornerRadius: compact ? 3 : 5).fill(selected ? theme.editorColors.blue.opacity(0.14) : .clear))
        }
        .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
        .accessibilityIdentifier("AdaEditor.Agent.Completion.\(entry.id)")
    }

    private func icon(for entry: EditorAgentCompletion) -> String {
        switch entry {
        case let .file(file): file.isDirectory ? "\u{E2C7}" : "\u{E24D}"
        case .skill: "\u{E65F}"
        case .command: "\u{EB8E}"
        }
    }
}

private struct EditorAgentDraftLayout: Layout {
    let accessoryHeight: Float

    func sizeThatFits(_ proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> Size {
        guard subviews.count == 2 else {
            return proposal.replacingUnspecifiedDimensions()
        }
        var ideal = ProposedViewSize.unspecified
        ideal.width = proposal.width
        let prompt = subviews[1].sizeThatFits(ideal)
        let height = prompt.height + accessoryHeight
        return Size(width: proposal.width ?? prompt.width, height: min(proposal.height ?? height, height))
    }

    func placeSubviews(in bounds: Rect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        guard subviews.count == 2 else {
            return
        }
        var ideal = ProposedViewSize.unspecified
        ideal.width = bounds.width
        let promptHeight = min(bounds.height, subviews[1].sizeThatFits(ideal).height)
        let remaining = max(0, bounds.height - promptHeight)
        let accessoryHeight = min(remaining, self.accessoryHeight)

        var accessoryProposal = ideal
        accessoryProposal.height = accessoryHeight
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: accessoryProposal)

        var promptProposal = ideal
        promptProposal.height = promptHeight
        subviews[1].place(at: Point(bounds.minX, bounds.minY + accessoryHeight), anchor: .topLeading, proposal: promptProposal)
    }
}

struct EditorAgentDesktopDraft: View {
    let viewModel: EditorAgentViewModel
    let isDocked: Bool
    let onCaret: (Rect) -> Void
    let maximumEditorHeight: Float
    let focusRequest: UInt64
    @Environment(\.theme) private var theme

    var body: some View {
        EditorAgentDraftLayout(accessoryHeight: accessoryHeight) {
            if accessoryHeight > 0 {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        draftContext
                        EditorSceneAnnotationChips(agent: viewModel)
                        EditorAgentSuggestionsView(viewModel: viewModel)
                    }
                }
            }
            EditorAgentPromptEditor(
                viewModel: viewModel,
                isDocked: isDocked,
                maximumHeight: maximumEditorHeight,
                focusRequest: focusRequest,
                onCaret: onCaret
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mask(RectangleShape())
        .background(isDocked ? theme.editorColors.background : theme.editorColors.surfaceElevated)
        .overlay(anchor: .top) {
            if isDocked {
                RectangleShape().fill(theme.editorColors.border).frame(height: 1).allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("AdaEditor.Agent.Composer")
    }

    private var hasDraftContext: Bool {
        viewModel.sceneContext != nil || viewModel.codeSelection != nil || !viewModel.pendingAttachments.isEmpty
    }

    private var accessoryHeight: Float {
        let annotations = viewModel.sceneAnnotations
        if annotations.draft?.editingID != nil {
            return 120
        }
        var height: Float = hasDraftContext ? 26 : 0
        if !annotations.items.isEmpty {
            height += 34
        }
        if annotations.error != nil {
            height += 48
        }
        let suggestions = viewModel.promptSuggestions
        if let purpose = suggestions.purpose, !suggestions.suggestions.isEmpty {
            height += purpose == .completion ? 80 : 120
        }
        return min(120, height)
    }

    @ViewBuilder
    private var draftContext: some View {
        if hasDraftContext {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    if let scene = viewModel.sceneContext {
                        EditorAgentDraftChip(title: "\(scene.sceneTitle) · \(scene.selectedEntityName)", symbol: "\u{F720}") {
                            viewModel.sceneContext = nil
                        }
                    }
                    if let code = viewModel.codeSelection {
                        EditorAgentDraftChip(title: L10n.text("Selected code · \(code.lineDescription)"), symbol: "\u{E86F}") {
                            viewModel.codeSelection = nil
                        }
                    }
                    ForEach(viewModel.pendingAttachments, id: \.id) { item in
                        EditorAgentDraftChip(title: item.name, symbol: item.mimeType.hasPrefix("image/") ? "\u{E3F4}" : "\u{E24D}") {
                            viewModel.removeAttachment(id: item.id)
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 26)
        }
    }
}
