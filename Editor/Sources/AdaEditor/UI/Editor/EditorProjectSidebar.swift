@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorProjectTreeIcon {
    static let chevronRight = "\u{E5CC}"
    static let expandMore = "\u{E5CF}"
    static let folder = "\u{E2C7}"
    static let folderOpen = "\u{E2C8}"
    static let description = "\u{E873}"
    static let code = "\u{E86F}"
    static let article = "\u{EF42}"
    static let image = "\u{E3F4}"
    static let audioFile = "\u{EB82}"
    static let scene = "\u{F720}"

    static let allSymbols = [
        chevronRight,
        expandMore,
        folder,
        folderOpen,
        description,
        code,
        article,
        image,
        audioFile,
        scene,
    ]
}

struct EditorProjectSidebar: View {
    let viewModel: EditorProjectSidebarViewModel
    let projectRootItem: EditorProjectSidebarViewModel.Item?
    let onOpenItem: (EditorProjectSidebarViewModel.Item) -> Void
    let onOpenRawItem: (EditorProjectSidebarViewModel.Item) -> Void
    let onNewFile: (EditorNewFileKind?) -> Void
    let onImportAssets: () -> Void
    let onDropFiles: ([URL]) -> Bool
    let onRevealItem: (EditorProjectSidebarViewModel.Item) -> Void
    let onOpenInDefaultApplication: (EditorProjectSidebarViewModel.Item) -> Void
    let onOpenInTerminal: (EditorProjectSidebarViewModel.Item) -> Void
    let onFindInFolder: (EditorProjectSidebarViewModel.Item) -> Void
    let onFindInProjectRoot: () -> Void
    let onCopyPath: (EditorProjectSidebarViewModel.Item, Bool) -> Void
    let onDeleteItem: (EditorProjectSidebarViewModel.Item) -> Void

    @State private var hoveredItemID: String?

    @Environment(\.metrics) private var metrics
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(anchor: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button(action: {
                        viewModel.toggleDisplayModeMenu()
                    }) {
                        HStack(spacing: 4) {
                            Text(viewModel.displayMode.title)
                                .font(.system(size: 14, weight: .bold))
                            Text(EditorProjectTreeIcon.expandMore)
                                .font(AdaEditorMaterialSymbolFont.font(size: 16))
                        }
                        .foregroundColor(theme.editorColors.text)
                        .frame(height: 24)
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .accessibilityIdentifier("AdaEditor.ProjectTree.DisplayMode.Menu")
                    Spacer()
                    Button(action: {
                        viewModel.isDisplayModeMenuPresented = false
                        onNewFile(nil)
                    }) {
                        HStack(spacing: 5) {
                            Text("+")
                                .font(.system(size: 14))
                            Text("New")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(theme.editorColors.blue)
                        .padding(.horizontal, 7)
                        .frame(height: 24)
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .accessibilityIdentifier("AdaEditor.ProjectTree.NewFile")
                }
                .padding(.horizontal, 12)
                .frame(height: 34)

                GeometryReader { geometry in
                    ZStack(anchor: .topLeading) {
                        projectTreeBackground(width: geometry.size.width, height: geometry.size.height)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(viewModel.visibleItems, id: \.id) { item in
                                    projectTreeRow(item)
                                }
                            }
                            .frame(width: max(0, geometry.size.width - 16), alignment: .leading)
                            .padding(8)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    }
                }
            }

            if viewModel.isDisplayModeMenuPresented {
                displayModeMenu
                    .offset(x: 12, y: 30)
                    .zIndex(10)
            }
        }
        .background(
            RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner)
                .fill(theme.editorColors.surfaceElevated)
        )
        .mask(RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner))
        #if canImport(AppKit) && os(macOS)
            .overlay {
                EditorProjectFileDropTarget(isEnabled: projectRootItem != nil, onDrop: onDropFiles)
                .nativeRenderingMode(.overlay)
                .allowsHitTesting(false)
            }
        #endif
    }

    private var newFileAction: some View {
        Button("New…") { onNewFile(nil) }
    }

    private var displayModeMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(EditorProjectSidebarViewModel.DisplayMode.allCases, id: \.rawValue) { displayMode in
                displayModeMenuItem(displayMode)
            }
        }
        .padding(4)
        .frame(width: 164, alignment: .leading)
        .background(RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.surfaceElevated))
        .overlay {
            RoundedRectangleShape(cornerRadius: 7)
                .stroke(theme.editorColors.border, lineWidth: 1)
        }
    }

    private func displayModeMenuItem(_ displayMode: EditorProjectSidebarViewModel.DisplayMode) -> some View {
        let isSelected = viewModel.displayMode == displayMode
        return Button(displayMode.title) {
            viewModel.selectDisplayMode(displayMode)
        }
        .font(.system(size: 13))
        .foregroundColor(isSelected ? theme.editorColors.text : theme.editorColors.muted)
        .padding(.horizontal, 10)
        .frame(width: 156, height: 30, alignment: .leading)
        .background(
            RoundedRectangleShape(cornerRadius: 5)
                .fill(isSelected ? theme.editorColors.blue.opacity(0.34) : Color.clear)
        )
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.ProjectTree.DisplayMode.\(displayMode.title)")
    }

    private func projectTreeBackground(width: Float, height: Float) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .contextMenu(onPresent: {
                if let projectRootItem {
                    viewModel.select(projectRootItem)
                }
            }) {
                newFileAction
                Button("Import Assets") {
                    onImportAssets()
                }
                Divider()
                if let projectRootItem {
                    Button("Reveal in Finder") {
                        onRevealItem(projectRootItem)
                    }
                    Button("Open in Terminal") {
                        onOpenInTerminal(projectRootItem)
                    }
                    Button("Find in Folder...") {
                        onFindInProjectRoot()
                    }
                    Button("Copy Path") {
                        onCopyPath(projectRootItem, false)
                    }
                    Divider()
                }
                Button("Expand All") {
                    viewModel.expandAll()
                }
                Button("Collapse All") {
                    viewModel.collapseAll()
                }
            }
            .accessibilityIdentifier("AdaEditor.ProjectTree.Background")
    }

    private func projectTreeRow(_ item: EditorProjectSidebarViewModel.Item) -> some View {
        Button(action: { onOpenItem(item) }) {
            HStack(spacing: 6) {
                Text(disclosureIcon(for: item))
                    .font(AdaEditorMaterialSymbolFont.font(size: 16))
                    .foregroundColor(theme.editorColors.muted)
                    .frame(width: 16, height: 18)
                Text(fileIcon(for: item))
                    .font(AdaEditorMaterialSymbolFont.font(size: 17))
                    .foregroundColor(iconColor(for: item))
                    .frame(width: 18, height: 18)
                Text(item.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(item.isActive ? theme.editorColors.text : theme.editorColors.muted)
                Spacer()
            }
            .padding(.leading, 6 + Float(item.level) * 16)
            .padding(.trailing, 6)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
            .background(
                RoundedRectangleShape(cornerRadius: 5)
                    .fill(projectTreeRowBackground(for: item))
            )
        }
        .buttonStyle(DefaultButtonStyle())
        .onHover { isHovered in
            if isHovered {
                hoveredItemID = item.id
            } else if hoveredItemID == item.id {
                hoveredItemID = nil
            }
        }
        .contextMenu(onPresent: { viewModel.select(item) }) {
            newFileAction
            Button(item.isFolder ? (viewModel.isCollapsed(item) ? "Expand" : "Collapse") : "Open") {
                onOpenItem(item)
            }
            if item.kind == .scene {
                Button("Open as Raw") {
                    onOpenRawItem(item)
                }
            }
            Divider()
            Button("Reveal in Finder") {
                onRevealItem(item)
            }
            if !item.isFolder {
                Button("Open in Default App") {
                    onOpenInDefaultApplication(item)
                }
            }
            Button("Open in Terminal") {
                onOpenInTerminal(item)
            }
            Button("Find in Folder...") {
                onFindInFolder(item)
            }
            Divider()
            Button("Copy Path") {
                onCopyPath(item, false)
            }
            Button("Copy Relative Path") {
                onCopyPath(item, true)
            }
            if item.isFolder {
                Divider()
                Button("Expand All") {
                    viewModel.expandAll()
                }
                Button("Collapse All") {
                    viewModel.collapseAll()
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                onDeleteItem(item)
            }
        }
        .accessibilityIdentifier("AdaEditor.ProjectTree.\(item.title)")
    }

    private func projectTreeRowBackground(for item: EditorProjectSidebarViewModel.Item) -> Color {
        if item.isActive {
            return theme.editorColors.blue.opacity(0.22)
        }
        if hoveredItemID == item.id {
            return theme.editorColors.blue.opacity(0.12)
        }
        return .clear
    }

    private func disclosureIcon(for item: EditorProjectSidebarViewModel.Item) -> String {
        guard item.isFolder else {
            return ""
        }

        return viewModel.isCollapsed(item) ? EditorProjectTreeIcon.chevronRight : EditorProjectTreeIcon.expandMore
    }

    private func fileIcon(for item: EditorProjectSidebarViewModel.Item) -> String {
        switch item.kind {
        case .folder:
            return viewModel.isCollapsed(item) ? EditorProjectTreeIcon.folder : EditorProjectTreeIcon.folderOpen
        case .scene:
            return EditorProjectTreeIcon.scene
        case let .text(language):
            return textFileIcon(for: language)
        case .image:
            return EditorProjectTreeIcon.image
        case .audio:
            return EditorProjectTreeIcon.audioFile
        case .genericAsset:
            return EditorProjectTreeIcon.description
        case .unsupported:
            return EditorProjectTreeIcon.description
        }
    }

    private func textFileIcon(for language: EditorSourceLanguage) -> String {
        switch language {
        case .json,
            .yaml:
            return EditorProjectTreeIcon.code
        case .markdown,
            .plainText:
            return EditorProjectTreeIcon.article
        case .packageManifest,
            .swift,
            .ada,
            .c,
            .cpp,
            .glsl,
            .wgsl,
            .metal:
            return EditorProjectTreeIcon.code
        }
    }

    private func iconColor(for item: EditorProjectSidebarViewModel.Item) -> Color {
        switch item.kind {
        case .scene:
            return theme.editorColors.purple
        case .text:
            return theme.editorColors.blue
        case .image:
            return theme.editorColors.blue
        case .audio:
            return theme.editorColors.purple
        case .genericAsset:
            return theme.editorColors.text.opacity(0.72)
        case .folder,
            .unsupported:
            return theme.editorColors.muted
        }
    }
}
