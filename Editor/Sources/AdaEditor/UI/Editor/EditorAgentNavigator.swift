@_spi(AdaEngine) import AdaEngine

/// Agent navigation is independent of the standard editor's selected tool panels.
enum EditorAgentNavigatorTab: String, CaseIterable {
    case files
    case workspaces
    case sourceControl

    var title: String {
        switch self {
        case .files: "Files"
        case .workspaces: "Workspaces"
        case .sourceControl: "Source Control"
        }
    }

    var icon: String {
        switch self {
        case .files: "\u{E2C7}"
        case .workspaces: "\u{E8F1}"
        case .sourceControl: "\u{F1C4}"
        }
    }
}

struct EditorAgentNavigator: View {
    let viewModel: EditorViewModel
    let tab: EditorAgentNavigatorTab
    let onSelectTab: (EditorAgentNavigatorTab?) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(tab == .sourceControl ? [tab] : [.files, .workspaces], id: \.self) { item in
                    Button(action: { onSelectTab(item) }) {
                        Text(L10n.tr(item.title))
                            .font(.system(size: 11, weight: tab == item ? .semibold : .regular))
                            .foregroundColor(tab == item ? theme.editorColors.blue : theme.editorColors.muted)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(height: 28)
                            .background(RoundedRectangleShape(cornerRadius: 5).fill(tab == item ? theme.editorColors.blue.opacity(0.14) : .clear))
                    }
                    .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
                    .accessibilityIdentifier("AdaEditor.AgentWorkspace.Navigator.Tab.\(item.rawValue)")
                }
                Spacer(minLength: 0)
                Button(action: { onSelectTab(nil) }) {
                    Text("\u{E5CD}").font(AdaEditorMaterialSymbolFont.font(size: 16)).frame(width: 24, height: 28)
                }
                .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
                .accessibilityIdentifier("AdaEditor.AgentWorkspace.Navigator.Close")
            }
            .padding(.horizontal, 6)
            .frame(height: 36)
            Divider()
            switch tab {
            case .files:
                EditorLeftSidebarContent(viewModel: viewModel, tool: "fileTree")
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            case .sourceControl:
                EditorSourceControlSidebar(viewModel: viewModel)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            case .workspaces:
                openWorkspaces
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .foregroundColor(theme.editorColors.text)
        .background(RoundedRectangleShape(cornerRadius: 9).fill(theme.editorColors.surface))
        .mask(RoundedRectangleShape(cornerRadius: 9))
        .overlay { adaEditorPanelBorder(theme: theme, cornerRadius: 9) }
        .accessibilityIdentifier("AdaEditor.AgentWorkspace.Navigator")
    }

    private var openWorkspaces: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 4) {
                if viewModel.workbench.openDocuments.isEmpty {
                    Text(L10n.text("Open a file to see its editor or preview here."))
                        .font(.system(size: 12))
                        .foregroundColor(theme.editorColors.muted)
                        .padding(12)
                }
                ForEach(viewModel.workbench.openDocuments, id: \.id) { document in
                    workspaceRow(document)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .accessibilityIdentifier("AdaEditor.AgentWorkspace.Workspaces")
    }

    private func workspaceRow(_ document: EditorWorkbenchDocument) -> some View {
        let selected = document.id == viewModel.workbench.activeDocumentID
        return Button(action: {
            viewModel.selectWorkbenchDocument(id: document.id)
            viewModel.interface.showsArtifact = true
        }) {
            HStack(spacing: 8) {
                Text(icon(for: document)).font(AdaEditorMaterialSymbolFont.font(size: 17))
                    .foregroundColor(theme.editorColors.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                    if !document.relativePath.isEmpty {
                        Text(document.relativePath).font(.system(size: 10)).foregroundColor(theme.editorColors.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if document.isDirty {
                    Circle().fill(theme.editorColors.blue).frame(width: 6, height: 6)
                }
            }
            .padding(8)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(EditorPickerRowButtonStyle(theme: theme, selectionColor: selected ? theme.editorColors.blue.opacity(0.14) : .clear))
        .accessibilityIdentifier("AdaEditor.AgentWorkspace.Workspace.\(document.id)")
    }

    private func icon(for document: EditorWorkbenchDocument) -> String {
        switch document {
        case .scene: EditorProjectTreeIcon.scene
        case .ui: EditorProjectTreeIcon.ui
        case .text: EditorProjectTreeIcon.code
        case .git: "\u{F1C4}"
        case .asset(let asset):
            switch asset.kind {
            case .image: EditorProjectTreeIcon.image
            case .audio: EditorProjectTreeIcon.audioFile
            case .model3D, .spine2D: EditorProjectTreeIcon.mesh
            default: EditorProjectTreeIcon.description
            }
        }
    }
}
