@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorInterfaceModeSwitcher: View {
    let state: EditorInterfaceState
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if AdaEngineStyleLayoutSpec.usesCompactWorkspace {
                let inEditor = state.mode == .editor
                EditorSceneToolbarButton(
                    title: inEditor ? "Switch to Agent" : "Switch to Editor",
                    symbol: inEditor ? "\u{E86F}" : "\u{E65F}",
                    identifier: "AdaEditor.InterfaceMode.Toggle",
                    compact: true,
                    tint: theme.editorColors.blue
                ) {
                    state.mode = inEditor ? .agent : .editor
                }
            } else {
                segmentedPicker
            }
        }
        .accessibilityIdentifier("AdaEditor.InterfaceMode")
    }

    private var segmentedPicker: some View {
        HStack(spacing: 2) {
            ForEach(EditorInterfaceMode.allCases, id: \.self) { mode in
                Button(action: { state.mode = mode }) {
                    Text(L10n.tr(mode.title))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(state.mode == mode ? theme.editorColors.blue : theme.editorColors.muted)
                        .frame(width: 48, height: 26)
                        .background(RoundedRectangleShape(cornerRadius: 5).fill(state.mode == mode ? theme.editorColors.blue.opacity(0.18) : .clear))
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.InterfaceMode.\(mode.rawValue)")
            }
        }
        .padding(2)
        .background(RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.surfaceElevated))
    }
}

/// A session-oriented shell; the standard editor's panel preferences remain independent.
struct EditorAgentWorkspace: View {
    let viewModel: EditorViewModel
    @Environment(\.theme) private var theme

    @State private var splitState = EditorWorkbenchResizeState()
    @State private var navigator: EditorAgentNavigatorTab?
    private var compact: Bool { AdaEngineStyleLayoutSpec.usesCompactWorkspace }

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(310, max(220, geometry.size.width * 0.25))
            let showsSidebar = geometry.size.width >= 680 && (navigator == nil || geometry.size.width >= 1200)
            HStack(spacing: 0) {
                if showsSidebar {
                    sessions.frame(width: sidebarWidth).padding(.trailing, compact ? 0 : 8)
                }
                conversationAndArtifact(showsHistory: !showsSidebar)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                if let navigator {
                    EditorAgentNavigator(viewModel: viewModel, tab: navigator, onSelectTab: selectNavigator)
                        .frame(width: min(300, geometry.size.width * 0.3))
                        .padding(.leading, compact ? 0 : 8)
                }
                navigationStrip.padding(.leading, compact ? 0 : 8)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityIdentifier("AdaEditor.AgentWorkspace")
    }

    private func conversationAndArtifact(showsHistory: Bool) -> some View {
        GeometryReader { geometry in
            let inlineArtifact = geometry.size.width >= 640
            if viewModel.interface.showsArtifact && inlineArtifact {
                let divider = compact ? AdaEngineStyleLayoutSpec.workspaceDividerSize : AdaEngineStyleLayoutSpec.dividerHitSize
                EditorWorkbenchPanelsLayout(state: splitState, dividerWidth: divider) {
                    conversation(showsHistory: showsHistory)
                    artifact
                    EditorResizeHandle(
                        axis: .horizontal,
                        onResize: { splitState.resize(translation: $0.width, availableWidth: geometry.size.width, dividerWidth: divider) },
                        onResizeEnded: { splitState.endDrag() },
                        showsGrip: !compact,
                        showsDivider: compact
                    )
                    .accessibilityIdentifier("AdaEditor.AgentWorkspace.ResizeArtifact")
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else if viewModel.interface.showsArtifact {
                artifact
            } else {
                conversation(showsHistory: showsHistory)
            }
        }
    }

    private func conversation(showsHistory: Bool) -> some View {
        EditorAgentSidebar(
            viewModel: viewModel.agent,
            onOpenCatalog: { viewModel.presentSettings(.agent) },
            presentation: .workspace,
            onOpenChangedFile: viewModel.openAgentChangedFile,
            showsSessionHistory: showsHistory
        )
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var navigationStrip: some View {
        VStack(spacing: 8) {
            adaEditorStripButton(
                .init(
                    identifier: "agent.artifact",
                    title: viewModel.interface.showsArtifact ? L10n.text("Back to Chat") : L10n.text("Show Workspace"),
                    icon: "\u{E8F1}"
                ),
                active: viewModel.interface.showsArtifact,
                theme: theme,
                tooltipEdge: .right,
                action: { viewModel.interface.showsArtifact.toggle() }
            )
            .accessibilityIdentifier("AdaEditor.AgentWorkspace.ToggleArtifact")
            Divider()
            ForEach(EditorAgentNavigatorTab.allCases, id: \.self) { tab in
                adaEditorStripButton(
                    .init(identifier: "agent.\(tab.rawValue)", title: L10n.tr(tab.title), icon: tab.icon),
                    active: navigator == tab,
                    theme: theme,
                    tooltipEdge: .right,
                    action: { selectNavigator(navigator == tab ? nil : tab) }
                )
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 36)
        .accessibilityIdentifier("AdaEditor.AgentWorkspace.Navigation")
    }

    private func selectNavigator(_ tab: EditorAgentNavigatorTab?) {
        navigator = tab
        if tab == .files {
            viewModel.projectSidebar.selectDisplayMode(.files)
        }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("Agent Sessions")).font(.system(size: 13, weight: .semibold))
                Spacer()
                if compact {
                    EditorSceneToolbarButton(
                        title: "New Session",
                        symbol: "\u{E145}",
                        identifier: "AdaEditor.AgentWorkspace.NewSession",
                        compact: true,
                        action: createSession
                    )
                } else {
                    Text("\(viewModel.agent.sessions.count)").font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                }
            }
            .padding(.horizontal, compact ? 8 : 14)
            .frame(height: compact ? AdaEngineStyleLayoutSpec.workspaceHeaderHeight : 36)
            .modifier(EditorWorkspaceHeader())
            if !compact {
                HStack(spacing: 6) {
                    outlinedButton("New Session", symbol: "\u{E145}") { createSession() }
                        .accessibilityIdentifier("AdaEditor.AgentWorkspace.NewSession")
                    outlinedButton("Add Project", symbol: "\u{E2C7}", action: viewModel.openProjectFromMenu)
                        .accessibilityIdentifier("AdaEditor.AgentWorkspace.AddProject")
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
            HStack(spacing: 8) {
                Text("\u{E2C7}").font(AdaEditorMaterialSymbolFont.font(size: 17))
                Text(viewModel.agent.projectName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.agent.sessions, id: \.id) { session in
                        sessionRow(session)
                        if viewModel.agent.activeSessionID == session.id {
                            changedFiles
                        }
                    }
                }
                .padding(.horizontal, compact ? 0 : 8)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .accessibilityIdentifier("AdaEditor.AgentWorkspace.Sessions.ScrollView")
            if compact {
                HStack(spacing: 3) {
                    EditorSceneToolbarButton(title: "Agent Settings", symbol: "\u{E8B8}", identifier: "AdaEditor.AgentWorkspace.Settings", compact: true) {
                        viewModel.presentSettings(.agent)
                    }
                    EditorSceneToolbarButton(
                        title: "Add Project",
                        symbol: "\u{E2C7}",
                        identifier: "AdaEditor.AgentWorkspace.AddProject",
                        compact: true,
                        action: viewModel.openProjectFromMenu
                    )
                    Spacer(minLength: 0)
                }
                .padding(4)
            } else {
                settingsButton
            }
        }
        .background(RoundedRectangleShape(cornerRadius: compact ? 0 : 9).fill(theme.editorColors.surface))
        .overlay { adaEditorPanelBorder(theme: theme, cornerRadius: compact ? 0 : 9) }
        .modifier(EditorPanelClip(cornerRadius: compact ? 0 : 9))
        .overlay(anchor: .trailing) {
            if compact {
                RectangleShape().fill(theme.editorColors.border).frame(width: 1).allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("AdaEditor.AgentWorkspace.Sessions")
    }

    private var settingsButton: some View {
        Button(action: { viewModel.presentSettings(.agent) }) {
            HStack(spacing: 8) {
                Text("\u{E8B8}").font(AdaEditorMaterialSymbolFont.font(size: 17))
                Text(L10n.text("Agent Settings")).font(.system(size: 12))
                Spacer()
            }
            .padding(12)
            .foregroundColor(theme.editorColors.muted)
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.AgentWorkspace.Settings")
    }

    private func sessionRow(_ session: EditorAgentSessionSummary) -> some View {
        let active = session.id == viewModel.agent.activeSessionID
        return Button(action: { viewModel.agent.selectSession(session) }) {
            HStack(spacing: 7) {
                if !compact {
                    Text(active ? "\u{E5CF}" : "\u{E5CC}").font(AdaEditorMaterialSymbolFont.font(size: 14))
                }
                if viewModel.agent.runningSessionID == session.id {
                    EditorFlipLoadingIndicator(size: 12, color: theme.editorColors.blue)
                } else if !compact {
                    Text("\u{E8F1}").font(AdaEditorMaterialSymbolFont.font(size: 15))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
                    if !compact {
                        Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundColor(theme.editorColors.muted).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, compact ? 0 : 8)
            .frame(minHeight: compact ? 27 : nil)
            .foregroundColor(theme.editorColors.text)
            .background(RoundedRectangleShape(cornerRadius: compact ? 0 : 5).fill(active ? theme.editorColors.blue.opacity(0.14) : .clear))
            .overlay(anchor: .leading) {
                if compact && active {
                    RectangleShape().fill(theme.editorColors.blue).frame(width: 2).allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(DefaultButtonStyle())
        .contextMenu { Button(L10n.text("Delete session")) { viewModel.agent.deleteSession(session) } }
        .accessibilityIdentifier("AdaEditor.AgentWorkspace.Session.\(session.id)")
    }

    private var changedFiles: some View {
        EditorAgentWorkspaceChangedFiles(viewModel: viewModel)
    }

    private var artifact: some View {
        let radius: Float = compact ? 0 : 9
        return VStack(spacing: 0) {
            HStack {
                Text(L10n.text("Workspace")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: { viewModel.interface.showsArtifact = false }) {
                    Text("\u{E5CD}").font(AdaEditorMaterialSymbolFont.font(size: 16)).frame(width: 28, height: 28)
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.AgentWorkspace.CloseArtifact")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            EditorDocumentWorkbench(viewModel: viewModel)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .foregroundColor(theme.editorColors.text)
        .background(RoundedRectangleShape(cornerRadius: radius).fill(theme.editorColors.surface))
        .modifier(EditorPanelClip(cornerRadius: radius))
        .overlay { adaEditorPanelBorder(theme: theme, cornerRadius: radius) }
        .accessibilityIdentifier("AdaEditor.AgentWorkspace.Artifact")
    }

    private func outlinedButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(symbol).font(AdaEditorMaterialSymbolFont.font(size: 15))
                Text(L10n.tr(title)).font(.system(size: 11)).lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .foregroundColor(theme.editorColors.text)
            .overlay { RoundedRectangleShape(cornerRadius: 4).stroke(theme.editorColors.border, lineWidth: 1) }
        }
        .buttonStyle(DefaultButtonStyle())
    }

    private func createSession() {
        Task {
            do { try await viewModel.agent.createSession() } catch { viewModel.agent.statusMessage = error.localizedDescription }
        }
    }
}

extension EditorViewModel {
    /// Open only project-contained files through the production document loader.
    func openAgentChangedFile(_ path: String) {
        guard let project else {
            return
        }
        let root = URL(fileURLWithPath: project.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let file = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else {
            agent.statusMessage = "The agent file is outside this project."
            return
        }
        let relativePath = String(file.path.dropFirst(root.path.count + 1))
        let items = Self.projectTreeItems(for: project, fileManager: fileManager)
        guard let item = items.first(where: { $0.relativePath == relativePath && !$0.isFolder }) else {
            agent.statusMessage = "This file is no longer available in the project: \(relativePath)"
            return
        }
        openProjectItem(item)
        interface.showsArtifact = true
    }
}
