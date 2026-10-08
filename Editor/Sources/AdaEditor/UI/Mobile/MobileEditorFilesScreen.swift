#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import Foundation

struct MobileEditorFilesScreen: View {
    @Environment(\.theme) private var theme
    let project: MobileEditorProject
    let onOpenFile: (String) -> Void

    @State private var files: [EditorProjectSidebarViewModel.Item] = []
    @State private var errorMessage: String?

    var body: some View {
        MobileEditorPageScrollView {
            fileList
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 112)
        }
        .background(theme.editorColors.background)
        .onAppear { refreshFiles() }
        .accessibilityIdentifier("AdaEditor.Mobile.Files")
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(project.title.uppercased())
                    .font(MobileEditorFont.font(size: 11))
                    .foregroundColor(theme.editorColors.blue)
                Spacer()
                Button("Refresh") { refreshFiles() }
                    .font(MobileEditorFont.font(size: 12))
                    .foregroundColor(theme.editorColors.blue)
                    .accessibilityIdentifier("AdaEditor.Mobile.Files.Refresh")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(MobileEditorFont.font(size: 12))
                    .foregroundColor(theme.editorColors.purple)
            } else if files.isEmpty {
                Text("No project files yet.")
                    .font(MobileEditorFont.font(size: 13))
                    .foregroundColor(theme.editorColors.muted)
            } else {
                VStack(spacing: 6) {
                    ForEach(files, id: \.id) { item in
                        fileRow(item)
                    }
                }
            }
        }
    }

    private func fileRow(_ item: EditorProjectSidebarViewModel.Item) -> some View {
        Button {
            Task { @MainActor in
                // Keep the tapped row in place until UIKit finishes delivering the touch.
                try? await Task.sleep(for: .milliseconds(80))
                onOpenFile(item.relativePath)
            }
        } label: {
            ZStack {
                RoundedRectangleShape(cornerRadius: 13)
                    .fill(theme.editorColors.surface)
                HStack(spacing: 12) {
                    fileIcon(for: item.kind)
                        .foregroundColor(theme.editorColors.blue)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangleShape(cornerRadius: 9).fill(theme.editorColors.blue.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(MobileEditorFont.font(size: 14))
                            .foregroundColor(theme.editorColors.text)
                            .lineLimit(1)
                        Text(item.relativePath)
                            .font(MobileEditorFont.font(size: 10))
                            .foregroundColor(theme.editorColors.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 62)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Mobile.Files.Item.\(item.relativePath)")
    }

    private func fileIcon(for kind: EditorProjectFileKind) -> some View {
        Text(fileSymbol(for: kind))
            .font(AdaEditorMaterialSymbolFont.font(size: 20))
    }

    private func fileSymbol(for kind: EditorProjectFileKind) -> String {
        switch kind {
        case .text: "\u{E86F}"
        case .scene: "\u{E8F1}"
        case .image: "\u{E3F4}"
        case .audio: "\u{EB82}"
        case .folder: "\u{E2C7}"
        case .genericAsset, .unsupported: "\u{E873}"
        }
    }

    private func refreshFiles() {
        do {
            let directory = try MobileAdaScriptProjectService.prepare(project)
            files = EditorViewModel.buildProjectTreeItems(at: directory, fileManager: .default)
                .filter { !$0.isFolder }
            errorMessage = nil
        } catch {
            files = []
            errorMessage = error.localizedDescription
        }
    }
}

#endif
