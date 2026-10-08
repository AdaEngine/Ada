@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorInterfaceModePicker: View {
    let state: EditorInterfaceState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditorInterfaceMode.allCases, id: \.self) { mode in
                Button(action: { state.mode = mode }) {
                    Text(mode.title)
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

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(310, max(220, geometry.size.width * 0.25))
            let showsSidebar = geometry.size.width >= 680
            let inlineArtifact = geometry.size.width >= 1000
            HStack(spacing: showsSidebar ? 8 : 0) {
                if showsSidebar {
                    sessions
                        .frame(width: sidebarWidth)
                }
                VStack(spacing: 0) {
                    workspaceTools
                    HStack(spacing: viewModel.interface.showsArtifact && inlineArtifact ? 8 : 0) {
                        if !viewModel.interface.showsArtifact || inlineArtifact {
                            EditorAgentSidebar(
                                viewModel: viewModel.agent,
                                onOpenCatalog: { viewModel.presentSettings(.agent) },
                                presentation: .workspace,
                                onOpenChangedFile: viewModel.openAgentChangedFile
                            )
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        }
                        if viewModel.interface.showsArtifact {
                            artifact
                                .frame(width: inlineArtifact ? geometry.size.width * 0.40 : nil)
                                .frame(
                                    minWidth: inlineArtifact ? nil : 0,
                                    maxWidth: inlineArtifact ? nil : .infinity,
                                    minHeight: 0,
                                    maxHeight: .infinity
                                )
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityIdentifier("AdaEditor.AgentWorkspace")
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agent Sessions").font(.system(size: 13, weight: .semibold))
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
            ScrollView {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button(action: { viewModel.presentSettings(.agent) }) {
                HStack(spacing: 8) {
                    Text("\u{E8B8}").font(AdaEditorMaterialSymbolFont.font(size: 17))
                    Text("Agent Settings").font(.system(size: 12))
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
        .contextMenu { Button("Delete session") { viewModel.agent.deleteSession(session) } }
        .accessibilityIdentifier("AdaEditor.AgentWorkspace.Session.\(session.id)")
    }

    private var changedFiles: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(EditorAgentSessionChanges.files(in: viewModel.agent.activeSession?.events ?? [])) { file in
                Button(action: { viewModel.openAgentChangedFile(file.path) }) {
                    HStack(spacing: 8) {
                        Text("\u{E24D}").font(AdaEditorMaterialSymbolFont.font(size: 14))
                        Text(file.title).font(.system(size: 12)).lineLimit(1)
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

    private var workspaceTools: some View {
        HStack(spacing: 8) {
            Text(viewModel.agent.projectName).font(.system(size: 11)).foregroundColor(theme.editorColors.muted).lineLimit(1)
            Spacer()
            Button(action: { viewModel.interface.showsArtifact.toggle() }) {
                HStack(spacing: 5) {
                    Text("\u{E8F1}").font(AdaEditorMaterialSymbolFont.font(size: 15))
                    Text(viewModel.interface.showsArtifact ? "Back to Chat" : "Show Workspace").font(.system(size: 11))
                }
                .foregroundColor(theme.editorColors.blue)
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.AgentWorkspace.ToggleArtifact")
            Button("Editor") { viewModel.interface.mode = .editor }
                .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                .accessibilityIdentifier("AdaEditor.AgentWorkspace.OpenEditor")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private var artifact: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workspace").font(.system(size: 12, weight: .semibold))
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
        .background(theme.editorColors.surface)
        .accessibilityIdentifier("AdaEditor.AgentWorkspace.Artifact")
    }

    private func outlinedButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(symbol).font(AdaEditorMaterialSymbolFont.font(size: 15))
                Text(title).font(.system(size: 11)).lineLimit(1)
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
