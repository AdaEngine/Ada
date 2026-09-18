@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorSceneHierarchyPresentation {
    case workspacePanel
    case embedded
}

struct EditorSceneHierarchySidebar: View {
    let document: EditorSceneDocument?
    let presentation: EditorSceneHierarchyPresentation
    let onSelectEntity: (String) -> Void
    let onToggleEntityExpanded: (String) -> Void
    let onAddEntity: (String?) -> Void
    let onSetEntityEnabled: (String, Bool) -> Void
    let onRenameEntity: (String, String) -> Void
    let onDeleteEntity: (String) -> Void
    let onDuplicateEntity: (String) -> Void
    let onCopyEntity: (String) -> Void
    let onPasteEntity: (String?) -> Void
    let onReparentEntity: (String, String) -> Void

    @Environment(\.metrics) private var metrics
    @Environment(\.theme) private var theme
    @State private var hoveredEntityID: String?
    @State private var renamingEntityID: String?
    @State private var renameDraft = ""
    @State private var draggedEntityID: String?
    @State private var dropTargetEntityID: String?

    init(
        document: EditorSceneDocument?,
        presentation: EditorSceneHierarchyPresentation = .workspacePanel,
        onSelectEntity: @escaping (String) -> Void,
        onToggleEntityExpanded: @escaping (String) -> Void,
        onAddEntity: @escaping (String?) -> Void = { _ in },
        onSetEntityEnabled: @escaping (String, Bool) -> Void = { _, _ in },
        onRenameEntity: @escaping (String, String) -> Void = { _, _ in },
        onDeleteEntity: @escaping (String) -> Void = { _ in },
        onDuplicateEntity: @escaping (String) -> Void = { _ in },
        onCopyEntity: @escaping (String) -> Void = { _ in },
        onPasteEntity: @escaping (String?) -> Void = { _ in },
        onReparentEntity: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.document = document
        self.presentation = presentation
        self.onSelectEntity = onSelectEntity
        self.onToggleEntityExpanded = onToggleEntityExpanded
        self.onAddEntity = onAddEntity
        self.onSetEntityEnabled = onSetEntityEnabled
        self.onRenameEntity = onRenameEntity
        self.onDeleteEntity = onDeleteEntity
        self.onDuplicateEntity = onDuplicateEntity
        self.onCopyEntity = onCopyEntity
        self.onPasteEntity = onPasteEntity
        self.onReparentEntity = onReparentEntity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hierarchyHeader

            if let document, let sceneModel = document.sceneModel {
                let items = EditorSceneHierarchyModel.visibleItems(for: sceneModel)
                GeometryReader { geometry in
                    ZStack(anchor: .topLeading) {
                        hierarchyBackground(sceneModel: sceneModel, size: geometry.size)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(items, id: \.id) { item in
                                    hierarchyRow(item, items: items, sceneModel: sceneModel)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    }
                }
            } else {
                emptyState
            }
        }
        .background(panelBackground)
        .mask(panelMask)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("AdaEditor.SceneHierarchy")
    }

    @ViewBuilder
    private var hierarchyHeader: some View {
        switch presentation {
        case .workspacePanel:
            adaEditorPanelTitle("HIERARCHY", trailing: trailingTitle, theme: theme)
        case .embedded:
            HStack(spacing: 8) {
                Text("Hierarchy")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.editorColors.text)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.blue.opacity(0.16)))
                Spacer()
                Text(trailingTitle)
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(1)
                Button(action: { onAddEntity(defaultParentID) }) {
                    Text("+")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.editorColors.blue)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.blue.opacity(0.14)))
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.SceneHierarchy.AddEntity")
            }
            .frame(height: 32)
            .padding(10)
            RectangleShape()
                .fill(theme.editorColors.border.opacity(0.45))
                .frame(height: 1)
        }
    }

    private var panelBackground: some View {
        RoundedRectangleShape(cornerRadius: presentation == .embedded ? 0 : metrics.panelsRoundedCorner)
            .fill(presentation == .embedded ? theme.editorColors.surface : theme.editorColors.surfaceElevated)
    }

    private var panelMask: RoundedRectangleShape {
        RoundedRectangleShape(cornerRadius: presentation == .embedded ? 0 : metrics.panelsRoundedCorner)
    }

    private var trailingTitle: String {
        guard let document, let sceneModel = document.sceneModel else {
            return ""
        }

        return "\(sceneModel.entities.count) entities"
    }

    private var defaultParentID: String? {
        document?.sceneModel?.editor?.selectedEntity ?? document?.sceneModel?.rootEntityID
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("\u{E24B}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 16))
                    .foregroundColor(theme.editorColors.muted)
                Text("No scene open")
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(1)
            }
            Text("Open a scene file to inspect its entities.")
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("AdaEditor.SceneHierarchy.EmptyState")
    }

    private func hierarchyBackground(sceneModel: EditorSceneModel, size: Size) -> some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .contextMenu {
                Button("Add") {
                    onAddEntity(sceneModel.rootEntityID)
                }
                Button("Paste") {
                    onPasteEntity(sceneModel.rootEntityID)
                }
            }
            .accessibilityIdentifier("AdaEditor.SceneHierarchy.Background")
    }

    private func hierarchyRow(
        _ item: EditorSceneHierarchyItem,
        items: [EditorSceneHierarchyItem],
        sceneModel: EditorSceneModel
    ) -> some View {
        let isHovered = hoveredEntityID == item.id
        let isDropTarget = dropTargetEntityID == item.id
        return HStack(alignment: .center, spacing: 4) {
            Button(action: {
                if item.hasChildren {
                    onToggleEntityExpanded(item.id)
                }
            }) {
                Text(disclosureIcon(for: item))
                    .font(AdaEditorMaterialSymbolFont.font(size: 13))
                    .foregroundColor(item.hasChildren ? theme.editorColors.muted : Color.clear)
                    .frame(width: 16, height: 34)
            }
            .buttonStyle(DefaultButtonStyle())
            .onHover { updateHover($0, entityID: item.id) }

            if renamingEntityID == item.id {
                HStack(spacing: 8) {
                    Text(EditorSceneHierarchyIcon.symbol(for: item))
                        .font(AdaEditorMaterialSymbolFont.font(size: 16))
                        .foregroundColor(theme.editorColors.blue)
                        .frame(width: 18, height: 18)
                        .accessibilityIdentifier("AdaEditor.SceneHierarchy.Icon.\(item.id)")
                    TextField("Entity name", text: Binding(get: { renameDraft }, set: { renameDraft = $0 }))
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(theme.editorColors.text)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 60, maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                        .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
                        .accessibilityIdentifier("AdaEditor.SceneHierarchy.RenameField.\(item.id)")
                    renameButton(symbol: "\u{E86C}", identifier: "Confirm", action: commitRename)
                    renameButton(symbol: "\u{E5CD}", identifier: "Cancel", action: cancelRename)
                }
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onHover { updateHover($0, entityID: item.id) }
            } else {
                HStack(spacing: 8) {
                    Text(EditorSceneHierarchyIcon.symbol(for: item))
                        .font(AdaEditorMaterialSymbolFont.font(size: 16))
                        .foregroundColor(item.isSelected ? theme.editorColors.blue : theme.editorColors.muted)
                        .frame(width: 18, height: 18)
                        .accessibilityIdentifier("AdaEditor.SceneHierarchy.Icon.\(item.id)")
                    Text(item.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(item.isEnabled ? theme.editorColors.text : theme.editorColors.muted)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
                .padding(.trailing, 30)
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask(RectangleShape())
                .overlay(anchor: .trailing) {
                    if item.isSelected {
                        Text("\u{E86C}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 15))
                            .foregroundColor(theme.editorColors.blue)
                            .frame(width: 18, height: 18)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("AdaEditor.SceneHierarchy.Selected.\(item.id)")
                    }
                }
                .gesture(
                    TapGesture()
                        .onEnded { onSelectEntity(item.id) }
                        .simultaneously(with: hierarchyDragGesture(for: item, items: items, sceneModel: sceneModel))
                )
                .accessibilityIdentifier("AdaEditor.SceneHierarchy.Select.\(item.id)")
                .onHover { updateHover($0, entityID: item.id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4 + Float(item.level) * 16)
        .background(rowBackground(item: item, isHovered: isHovered, isDropTarget: isDropTarget))
        .overlay(anchor: .leading) {
            if item.isSelected {
                RectangleShape()
                    .fill(theme.editorColors.blue)
                    .frame(width: 3, height: 26)
                    .allowsHitTesting(false)
            }
        }
        .overlay(anchor: .bottom) {
            theme.editorColors.border.opacity(0.72)
                .frame(height: 1)
                .allowsHitTesting(false)
                .accessibilityIdentifier("AdaEditor.SceneHierarchy.Separator.\(item.id)")
        }
        .contextMenu(onPresent: { onSelectEntity(item.id) }) {
            Button("Add Child") {
                onAddEntity(item.id)
            }
            Divider()
            Button(item.isEnabled ? "Hide" : "Show") {
                onSetEntityEnabled(item.id, !item.isEnabled)
            }
            Button("Rename") {
                beginRename(item)
            }
            if !sceneModel.isRootEntity(item.id) {
                Button("Duplicate") {
                    onDuplicateEntity(item.id)
                }
            }
            Button("Copy") {
                onCopyEntity(item.id)
            }
            Button("Paste as Child") {
                onPasteEntity(item.id)
            }
            if !sceneModel.isRootEntity(item.id) {
                Divider()
                Button("Delete", role: .destructive) {
                    onDeleteEntity(item.id)
                }
            }
        }
        .accessibilityIdentifier("AdaEditor.SceneHierarchy.Row.\(item.id)")
    }

    private func disclosureIcon(for item: EditorSceneHierarchyItem) -> String {
        guard item.hasChildren else {
            return ""
        }

        return item.isExpanded ? "\u{E5CF}" : "\u{E5CC}"
    }

    private func rowBackground(item: EditorSceneHierarchyItem, isHovered: Bool, isDropTarget: Bool) -> some View {
        let color =
            if isDropTarget {
                theme.editorColors.blue.opacity(0.38)
            } else if item.isSelected {
                theme.editorColors.blue.opacity(0.24)
            } else if isHovered {
                theme.editorColors.surface
            } else {
                Color.clear
            }
        let state = isDropTarget ? "dropTarget" : (item.isSelected ? "selected" : (isHovered ? "hovered" : "normal"))
        return RoundedRectangleShape(cornerRadius: 5)
            .fill(color)
            .allowsHitTesting(false)
            .accessibilityIdentifier("AdaEditor.SceneHierarchy.RowState.\(item.id).\(state)")
    }

    private func beginRename(_ item: EditorSceneHierarchyItem) {
        onSelectEntity(item.id)
        renamingEntityID = item.id
        renameDraft = item.name
    }

    private func updateHover(_ isHovering: Bool, entityID: String) {
        if isHovering {
            hoveredEntityID = entityID
        } else if hoveredEntityID == entityID {
            hoveredEntityID = nil
        }
    }

    private func commitRename() {
        guard let renamingEntityID else {
            return
        }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return
        }
        onRenameEntity(renamingEntityID, name)
        cancelRename()
    }

    private func cancelRename() {
        renamingEntityID = nil
        renameDraft = ""
    }

    private func renameButton(symbol: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(AdaEditorMaterialSymbolFont.font(size: 14))
                .foregroundColor(theme.editorColors.text)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.SceneHierarchy.Rename.\(identifier)")
    }

    private func hierarchyDragGesture(
        for item: EditorSceneHierarchyItem,
        items: [EditorSceneHierarchyItem],
        sceneModel: EditorSceneModel
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !sceneModel.isRootEntity(item.id) else {
                    return
                }
                draggedEntityID = item.id
                dropTargetEntityID = dragTargetEntityID(
                    for: item,
                    translationY: value.translation.height,
                    items: items,
                    sceneModel: sceneModel
                )
            }
            .onEnded { value in
                defer {
                    draggedEntityID = nil
                    dropTargetEntityID = nil
                }
                guard
                    draggedEntityID == item.id,
                    let targetID = dragTargetEntityID(
                        for: item,
                        translationY: value.translation.height,
                        items: items,
                        sceneModel: sceneModel
                    )
                else {
                    return
                }
                onReparentEntity(item.id, targetID)
            }
    }

    private func dragTargetEntityID(
        for item: EditorSceneHierarchyItem,
        translationY: Float,
        items: [EditorSceneHierarchyItem],
        sceneModel: EditorSceneModel
    ) -> String? {
        guard let sourceIndex = items.firstIndex(where: { $0.id == item.id }) else {
            return nil
        }
        let rowOffset = Int((translationY / 34).rounded())
        guard rowOffset != 0 else {
            return nil
        }
        let targetIndex = min(items.count - 1, max(0, sourceIndex + rowOffset))
        let target = items[targetIndex]
        return sceneModel.canReparentEntity(item.id, to: target.id) ? target.id : nil
    }
}

enum EditorSceneHierarchyIcon {
    static let entity = "\u{E97A}"
    static let image = "\u{E3F4}"
    static let audio = "\u{EB82}"
    static let scene = "\u{E2C7}"

    static let allSymbols = [entity, image, audio, scene]

    static func symbol(for item: EditorSceneHierarchyItem) -> String {
        let componentNames = item.componentNames.map { $0.lowercased() }
        if componentNames.contains(where: { $0.contains("sceneinstance") }) {
            return scene
        }
        if componentNames.contains(where: { $0.contains("sprite") || $0.contains("texture") }) {
            return image
        }
        if componentNames.contains(where: { $0.contains("audio") }) {
            return audio
        }
        return entity
    }
}
