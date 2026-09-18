@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorContextualInspector: View {
    let document: EditorWorkbenchDocument?
    let workbench: EditorWorkbenchViewModel
    let sceneInspectorViewModel: EditorInspectorSidebarViewModel
    let resourceRootURL: URL?

    @Environment(\.metrics) private var metrics
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(anchor: .topLeading) {
            contextualContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner)
                .fill(theme.editorColors.surfaceElevated)
        )
        .mask(RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("AdaEditor.ContextualInspector")
    }

    private var contextualContent: AnyView {
        switch document {
        case .scene:
            return AnyView(EditorInspectorSidebar(viewModel: sceneInspectorViewModel))
        case let .ui(document):
            return AnyView(
                EditorUISceneEditor(
                    model: workbench.uiSceneModel(
                        for: document,
                        resourceRoot: resourceRootURL,
                        bindingCatalog: sceneInspectorViewModel.scriptableObjectCatalog
                    ),
                    colorPalette: workbench.codeColorPalette,
                    presentation: .inspector
                )
            )
        case let .text(document):
            return AnyView(EditorFileInspector(document: .text(document)))
        case let .asset(document):
            return AnyView(EditorFileInspector(document: .asset(document)))
        case let .git(document):
            return AnyView(EditorFileInspector(document: .git(document)))
        case nil:
            return AnyView(EditorFileInspector(document: nil))
        }
    }
}

struct EditorFileInspector: View {
    let document: EditorWorkbenchDocument?

    @Environment(\.metrics) private var metrics
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            adaEditorInspectorTitle(theme: theme)
            ScrollView(.vertical) {
                if let document {
                    VStack(alignment: .leading, spacing: 16) {
                        fileHeader(document)
                        inspectorSection("FILE") {
                            metadataRows(document)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    inspectorSection("SELECTION") {
                        Text("Open a document to inspect it.")
                            .font(.system(size: 11))
                            .foregroundColor(theme.editorColors.muted)
                    }
                }
            }
        }
        .background(
            RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner)
                .fill(theme.editorColors.surfaceElevated)
        )
        .mask(RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("AdaEditor.FileInspector")
    }

    private func fileHeader(_ document: EditorWorkbenchDocument) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(document.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.editorColors.text)
                .lineLimit(2)
            if !document.relativePath.isEmpty {
                Text(document.relativePath)
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataRows(_ document: EditorWorkbenchDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            metadataRow("Kind", documentKind(document))
            if !document.relativePath.isEmpty {
                metadataRow("Path", document.relativePath)
            }
            if let absolutePath = document.absolutePath {
                metadataRow("Location", URL(fileURLWithPath: absolutePath).deletingLastPathComponent().path)
                let values = try? URL(fileURLWithPath: absolutePath).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                if let fileSize = values?.fileSize {
                    metadataRow("Size", ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
                }
                if let modifiedAt = values?.contentModificationDate {
                    metadataRow("Modified", modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if document.isDirty {
                metadataRow("Status", "Modified")
            }
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(theme.editorColors.muted)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.text)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("AdaEditor.FileInspector.(label)")
    }

    private func documentKind(_ document: EditorWorkbenchDocument) -> String {
        switch document {
        case .scene:
            return "Scene"
        case .ui:
            return "UI Document"
        case let .text(document):
            return sourceLanguageTitle(document.language)
        case let .asset(document):
            return document.kind.rawValue.capitalized
        case .git:
            return "Source Control"
        }
    }

    private func sourceLanguageTitle(_ language: EditorSourceLanguage) -> String {
        switch language {
        case .ada:
            return "AdaScript Source"
        case .packageManifest:
            return "Swift Package Manifest"
        case .plainText:
            return "Text File"
        default:
            return "\(language.rawValue.uppercased()) Source"
        }
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.blue)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
