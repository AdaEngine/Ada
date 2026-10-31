@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorInterfaceModePicker: View {
    let state: EditorInterfaceState
    @Environment(\.theme) private var theme

    var body: some View {
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
        .accessibilityIdentifier("AdaEditor.InterfaceMode")
    }
}

/// A session-oriented shell; the standard editor's panel preferences remain independent.
struct EditorAgentWorkspace: View {
    let viewModel: EditorViewModel
    @Environment(\.theme) private var theme

    @State private var splitState = EditorWorkbenchResizeState()
    @State private var navigator: EditorAgentNavigatorTab?

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(310, max(220, geometry.size.width * 0.25))
            let showsSidebar = geometry.size.width >= 680 && (navigator == nil || geometry.size.width >= 1200)
            HStack(spacing: 0) {
                if showsSidebar {
                    sessions.frame(width: sidebarWidth).padding(.trailing, 8)
                }
                conversationAndArtifact
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                if let navigator {
                    EditorAgentNavigator(viewModel: viewModel, tab: navigator, onSelectTab: selectNavigator)
                        .frame(width: min(300, geometry.size.width * 0.3))
                        .padding(.leading, 8)
                }
                navigationStrip.padding(.leading, 8)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityIdentifier("AdaEditor.AgentWorkspace")
    }

    private var conversationAndArtifact: some View {
        GeometryReader { geometry in
            let inlineArtifact = geometry.size.width >= 640
            if viewModel.interface.showsArtifact && inlineArtifact {
                EditorWorkbenchPanelsLayout(state: splitState) {
                    conversation
                    EditorResizeHandle(
                        axis: .horizontal,
                        onResize: { splitState.resize(translation: $0.width, availableWidth: geometry.size.width) },
                        onResizeEnded: { splitState.endDrag() },
                        showsGrip: true
                    )
                    .accessibilityIdentifier("AdaEditor.AgentWorkspace.ResizeArtifact")
                    artifact
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else if viewModel.interface.showsArtifact {
                artifact
            } else {
                conversation
            }
        }
    }

    private var conversation: some View {
        EditorAgentSidebar(
            viewModel: viewModel.agent,
            onOpenCatalog: { viewModel.presentSettings(.agent) },
            presentation: .workspace,
            onOpenChangedFile: viewModel.openAgentChangedFile
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
                Text("\(viewModel.agent.sessions.count)").font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            HStack(spacing: 6) {
                outlinedButton("New Session", symbol: "\u{E145}") { createSession() }
                    .accessibilityIdentifier("AdaEditor.AgentWorkspace.NewSession")
                outlinedButton("Add Project", symbol: "\u{E2C7}", action: viewModel.openProjectFromMenu)
                    .accessibilityIdentifier("AdaEditor.AgentWorkspace.AddProject")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
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
                        if viewModel.agent.activeSession?.id == session.id {
                            changedFiles
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .accessibilityIdentifier("AdaEditor.AgentWorkspace.Sessions.ScrollView")
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
        .background(RoundedRectangleShape(cornerRadius: 9).fill(theme.editorColors.surface))
        .overlay { adaEditorPanelBorder(theme: theme, cornerRadius: 9) }
        .mask(RoundedRectangleShape(cornerRadius: 9))
        .accessibilityIdentifier("AdaEditor.AgentWorkspace.Sessions")
    }

    private func sessionRow(_ session: EditorAgentSessionSummary) -> some View {
        let active = session.id == viewModel.agent.activeSession?.id
        return Button(action: { viewModel.agent.selectSession(session) }) {
            HStack(spacing: 7) {
                Text(active ? "\u{E5CF}" : "\u{E5CC}").font(AdaEditorMaterialSymbolFont.font(size: 14))
                if viewModel.agent.runningSessionID == session.id {
                    EditorFlipLoadingIndicator(size: 12, color: theme.editorColors.blue)
                } else {
                    Text("\u{E8F1}").font(AdaEditorMaterialSymbolFont.font(size: 15))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10)).foregroundColor(theme.editorColors.muted).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .foregroundColor(theme.editorColors.text)
            .background(RoundedRectangleShape(cornerRadius: 5).fill(active ? theme.editorColors.blue.opacity(0.14) : .clear))
        }
        .buttonStyle(DefaultButtonStyle())
        .contextMenu { Button(L10n.text("Delete session")) { viewModel.agent.deleteSession(session) } }
        .accessibilityIdentifier("AdaEditor.AgentWorkspace.Session.\(session.id)")
    }

    private var changedFiles: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(EditorAgentSessionChanges.files(in: viewModel.agent.activeSession?.events ?? [])) { file in
                Button(action: { viewModel.openAgentChangedFile(file.path) }) {
                    HStack(spacing: 8) {
                        Text("\u{E24D}").font(AdaEditorMaterialSymbolFont.font(size: 14))
                        Text(L10n.tr(file.title)).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                    }
                    .foregroundColor(theme.editorColors.blue)
                    .padding(.leading, 32)
                    .padding(.trailing, 8)
                    .frame(height: 28)
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.AgentWorkspace.File.\(file.path)")
            }
        }
    }

    private var artifact: some View {
        VStack(spacing: 0) {
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
        .background(RoundedRectangleShape(cornerRadius: 9).fill(theme.editorColors.surface))
        .mask(RoundedRectangleShape(cornerRadius: 9))
        .overlay { adaEditorPanelBorder(theme: theme, cornerRadius: 9) }
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
