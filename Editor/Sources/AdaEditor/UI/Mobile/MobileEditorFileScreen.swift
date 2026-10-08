#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import Foundation

struct MobileEditorFileCover: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let project: MobileEditorProject
    let relativePath: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Text("\u{E5CD}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 24))
                        .foregroundColor(theme.editorColors.text)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: .circle)
                }
                .accessibilityIdentifier("AdaEditor.Mobile.File.Close")
                Spacer()
                Text(URL(fileURLWithPath: relativePath).lastPathComponent)
                    .font(MobileEditorFont.navigationFont(size: 18))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(1)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            .frame(height: 92)

            MobileEditorFileScreen(project: project, relativePath: relativePath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.safeAreaInsets, EdgeInsets())
        .background(theme.editorColors.background.ignoresSafeArea())
        .accessibilityIdentifier("AdaEditor.Mobile.FileCover")
    }
}

struct MobileEditorFileScreen: View {
    @Environment(\.theme) private var theme
    let project: MobileEditorProject
    let relativePath: String

    @State private var document: EditorWorkbenchDocument?
    @State private var projectRootURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if case let .scene(scene)? = document, let projectRootURL {
                MobileEditorSceneEditor(document: scene, projectRootURL: projectRootURL)
                    .id(scene.id)
            } else if let sourceDocument {
                MobileEditorCodeEditor(document: sourceDocument)
                    .id(sourceDocument.id)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let errorMessage {
                            Text(errorMessage)
                                .font(MobileEditorFont.font(size: 13))
                                .foregroundColor(theme.editorColors.muted)
                        } else if let document {
                            documentPreview(document)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
            }
        }
        .background(theme.editorColors.background)
        .onAppear { loadDocument() }
        .accessibilityIdentifier("AdaEditor.Mobile.File")
    }

    private var sourceDocument: EditorTextDocument? {
        switch document {
        case let .text(text), let .ui(text): text
        default: nil
        }
    }

    @ViewBuilder
    private func documentPreview(_ document: EditorWorkbenchDocument) -> some View {
        Text(document.relativePath)
            .font(MobileEditorFont.font(size: 11))
            .foregroundColor(theme.editorColors.muted)

        switch document {
        case let .text(text), let .ui(text):
            sourcePreview(text.content, errorMessage: text.errorMessage)
        case let .asset(asset):
            assetPreview(asset)
        case .scene:
            Text("Scene editor unavailable")
                .font(MobileEditorFont.font(size: 12))
                .foregroundColor(theme.editorColors.muted)
        case .git:
            Text("Preview unavailable")
                .font(MobileEditorFont.font(size: 12))
                .foregroundColor(theme.editorColors.muted)
        }
    }

    private func sourcePreview(_ content: String, errorMessage: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage {
                Text(errorMessage)
                    .font(MobileEditorFont.font(size: 12))
                    .foregroundColor(theme.editorColors.purple)
            }
            Text(String(content.prefix(80_000)))
                .font(MobileEditorFont.font(size: 11))
                .foregroundColor(theme.editorColors.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if content.count > 80_000 {
                Text("Preview limited to the first 80,000 characters.")
                    .font(MobileEditorFont.font(size: 11))
                    .foregroundColor(theme.editorColors.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangleShape(cornerRadius: 12).fill(theme.editorColors.surface))
        .accessibilityIdentifier("AdaEditor.Mobile.Files.SourcePreview")
    }

    @ViewBuilder
    private func assetPreview(_ asset: EditorAssetDocument) -> some View {
        if asset.kind == .image, let path = asset.absolutePath,
           let image = try? Image(contentsOf: URL(fileURLWithPath: path)) {
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: 280)
                .background(RoundedRectangleShape(cornerRadius: 12).fill(theme.editorColors.surface))
                .accessibilityIdentifier("AdaEditor.Mobile.Files.ImagePreview")
        }
        MobileEditorCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(asset.kind == .audio ? "Audio asset" : "Asset")
                    .font(MobileEditorFont.font(size: 13))
                    .foregroundColor(theme.editorColors.blue)
                Text(asset.assetReference ?? asset.relativePath)
                    .font(MobileEditorFont.font(size: 12))
                    .foregroundColor(theme.editorColors.text)
                if let byteCount = asset.byteCount {
                    Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                        .font(MobileEditorFont.font(size: 11))
                        .foregroundColor(theme.editorColors.muted)
                }
                if let errorMessage = asset.errorMessage {
                    Text(errorMessage)
                        .font(MobileEditorFont.font(size: 11))
                        .foregroundColor(theme.editorColors.purple)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let path = asset.absolutePath,
           let source = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) {
            sourcePreview(source, errorMessage: nil)
        }
    }

    private func loadDocument() {
        do {
            let directory = try MobileAdaScriptProjectService.prepare(project)
            let item = EditorViewModel.buildProjectTreeItems(at: directory, fileManager: .default)
                .first { !$0.isFolder && $0.relativePath == relativePath }
            guard let item else {
                document = nil
                errorMessage = "File is no longer in this project."
                return
            }
            projectRootURL = directory
            document = EditorViewModel.document(for: item)
            errorMessage = nil
        } catch {
            document = nil
            projectRootURL = nil
            errorMessage = error.localizedDescription
        }
    }
}
#endif
