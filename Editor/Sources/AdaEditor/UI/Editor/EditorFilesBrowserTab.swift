@_spi(AdaEngine) import AdaEngine

struct EditorFilesBrowserTab: View {
    let items: [EditorProjectSidebarViewModel.Item]
    let onOpenItem: (EditorProjectSidebarViewModel.Item) -> Void

    @State private var searchText = ""
    @Environment(\.theme) private var theme

    private var filteredItems: [EditorProjectSidebarViewModel.Item] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items
            .filter { !$0.isFolder }
            .filter { item in
                query.isEmpty
                    || item.title.localizedCaseInsensitiveContains(query)
                    || item.relativePath.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PROJECT FILES")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                Spacer()
                Text("\(filteredItems.count) files")
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
            }
            .padding(.horizontal, 18)
            .frame(height: 42)

            TextField("Filter files by name or path", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    RoundedRectangleShape(cornerRadius: 6)
                        .fill(theme.editorColors.surface)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .accessibilityIdentifier("AdaEditor.Files.Filter")

            if filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Text(items.isEmpty ? "Open a project to browse its files." : "No matching files.")
                        .font(.system(size: 13))
                        .foregroundColor(theme.editorColors.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filteredItems, id: \.id) { item in
                            fileRow(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(theme.editorColors.surfaceElevated)
        .accessibilityIdentifier("AdaEditor.Files.Browser")
    }

    private func fileRow(_ item: EditorProjectSidebarViewModel.Item) -> some View {
        Button(action: { onOpenItem(item) }) {
            HStack(spacing: 12) {
                Text(icon(for: item))
                    .font(AdaEditorMaterialSymbolFont.font(size: 17))
                    .foregroundColor(color(for: item))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundColor(theme.editorColors.text)
                        .lineLimit(1)
                    Text(item.relativePath)
                        .font(.system(size: 11))
                        .foregroundColor(theme.editorColors.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(kindLabel(for: item))
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface.opacity(0.5)))
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Files.Item.\(item.relativePath)")
    }

    private func icon(for item: EditorProjectSidebarViewModel.Item) -> String {
        switch item.kind {
        case .scene:
            EditorProjectTreeIcon.scene
        case .text:
            EditorProjectTreeIcon.code
        case .image:
            EditorProjectTreeIcon.image
        case .audio:
            EditorProjectTreeIcon.audioFile
        case .genericAsset,
            .unsupported:
            EditorProjectTreeIcon.description
        case .folder:
            EditorProjectTreeIcon.folder
        }
    }

    private func kindLabel(for item: EditorProjectSidebarViewModel.Item) -> String {
        switch item.kind {
        case .scene:
            "Scene"
        case .text:
            "Code"
        case .image:
            "Image"
        case .audio:
            "Audio"
        case .genericAsset:
            "Asset"
        case .unsupported:
            "File"
        case .folder:
            "Folder"
        }
    }

    private func color(for item: EditorProjectSidebarViewModel.Item) -> Color {
        switch item.kind {
        case .scene,
            .audio:
            theme.editorColors.purple
        case .text,
            .image:
            theme.editorColors.blue
        case .genericAsset,
            .unsupported,
            .folder:
            theme.editorColors.muted
        }
    }
}
