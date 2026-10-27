import AdaEngine

struct EditorTestsPanel: View {
    let viewModel: EditorViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(L10n.text("Run All Tests")) { viewModel.runTests(filter: "") }
                    .disabled(viewModel.workspaceTask != nil || viewModel.tests.isRunning || viewModel.tests.isDiscovering)
                Button(L10n.text("Refresh Tests")) { refresh() }
                    .disabled(viewModel.tests.isRunning || viewModel.tests.isDiscovering)
                if viewModel.tests.isDiscovering {
                    Text(L10n.text("Discovering tests…"))
                }
            }
            if let message = viewModel.tests.message {
                Text(message).foregroundColor(theme.editorColors.purple)
            } else if viewModel.tests.items.isEmpty && !viewModel.tests.isDiscovering {
                Text(L10n.text("No tests found. Add tests to your project, then refresh."))
                    .foregroundColor(theme.editorColors.muted)
            }
            ForEach(viewModel.tests.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(glyph(item.status)).environment(\.font, AdaEditorMaterialSymbolFont.font(size: 17))
                            .foregroundColor(item.status == .failed ? theme.editorColors.purple : theme.editorColors.blue)
                        Text(item.name).foregroundColor(theme.editorColors.text)
                        Text(L10n.tr(item.status.rawValue)).foregroundColor(theme.editorColors.muted)
                        Button(L10n.text("Run Test")) { viewModel.runTest(item) }
                            .disabled(viewModel.workspaceTask != nil || viewModel.tests.isRunning || viewModel.tests.isDiscovering)
                    }
                    Text(item.path.isEmpty ? item.filter : "\(item.path):\(item.line)")
                        .foregroundColor(theme.editorColors.muted)
                    if !item.detail.isEmpty { Text(item.detail).foregroundColor(theme.editorColors.muted) }
                }
                .accessibilityIdentifier("AdaEditor.Tests.\(item.id)")
            }
        }
        .font(.system(size: 12))
        .onAppear { refresh() }
    }

    private func refresh() { viewModel.tests.refresh(projectURL: viewModel.projectURL, service: viewModel.workspaceService) }

    private func glyph(_ status: EditorTestItem.Status) -> String {
        switch status {
        case .notRun: "\u{E836}"
        case .running: "\u{E037}"
        case .passed: "\u{E86C}"
        case .failed: "\u{E000}"
        case .skipped: "\u{E047}"
        }
    }
}
