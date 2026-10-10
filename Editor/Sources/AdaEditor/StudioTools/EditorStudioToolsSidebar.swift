import AdaEngine

struct EditorStudioToolsSidebar: View {
    let host: EditorStudioToolHost
    var onOpenSettings: () -> Void = {}
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("STUDIO TOOLS").font(.system(size: 12, weight: .bold))
                Spacer()
                Button {
                    host.reload()
                } label: {
                    Text("\u{E5D5}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 18))
                        .frame(width: 28, height: 28)
                }
                .accessibilityIdentifier("studio.tools.reload")
                Button(action: onOpenSettings) {
                    Text("\u{E8B8}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 18))
                        .frame(width: 28, height: 28)
                }
                .accessibilityIdentifier("studio.tools.settings")
            }
            if let error = host.error {
                Text(error).foregroundColor(Color(red: 0.9, green: 0.3, blue: 0.2)).font(.system(size: 11))
            }
            if !host.reviewCandidateIDs.isEmpty {
                Button("Review Tool Access") { host.reviewAvailableTools() }
                    .accessibilityIdentifier("studio.tools.review-access")
            }
            if let panel = host.selectedPanel {
                if host.panels.count > 1 {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(host.panels, id: \.id) { item in
                                Button(item.title) { host.selectedPanelID = item.id }
                            }
                        }
                    }
                    .frame(height: 32)
                }
                Text(panel.title).font(.system(size: 14, weight: .bold))
                if let error = panel.error {
                    Text(error).foregroundColor(Color(red: 0.9, green: 0.3, blue: 0.2)).font(.system(size: 11))
                }
                UISceneView(session: panel.session)
                    .id(panel.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text(host.definitions.isEmpty ? "Add a .ada tool and its .ui under Tools/ in this project." : "Tool access is managed in Project Settings.")
                    .font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.editorColors.surfaceElevated)
        .accessibilityIdentifier("studio.tools.sidebar")
        .onAppear { host.reviewAvailableTools() }
    }
}
