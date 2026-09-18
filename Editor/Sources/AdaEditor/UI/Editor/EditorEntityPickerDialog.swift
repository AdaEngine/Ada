@_spi(AdaEngine) import AdaEngine

struct EditorEntityPickerRequest: Hashable {
    let documentID: String
    let parentID: String?
}

struct EditorEntityPickerDialog: View {
    let workbench: EditorWorkbenchViewModel
    let request: EditorEntityPickerRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var search = ""

    private var parentName: String {
        guard
            let parentID = request.parentID,
            let model = workbench.sceneDocument(id: request.documentID)?.sceneModel,
            let parent = model.entities.first(where: { $0.id == parentID })
        else {
            return "scene root"
        }
        return parent.name
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, min(840, geometry.size.width - 32))
            let height = max(0, min(620, geometry.size.height - 32))
            ZStack(anchor: .center) {
                Color.black.opacity(0.54)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { close() }
                    .accessibilityIdentifier("AdaEditor.EntityPicker.Backdrop")
                VStack(alignment: .leading, spacing: 0) {
                    header
                    searchField
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    templateGrid(width: width, height: max(0, height - 160))
                    footer
                }
                .frame(width: width, height: height)
                .background(RoundedRectangleShape(cornerRadius: 12).fill(theme.editorColors.surfaceElevated))
                .overlay { RoundedRectangleShape(cornerRadius: 12).stroke(theme.editorColors.border, lineWidth: 1) }
                .accessibilityIdentifier("AdaEditor.EntityPicker.Dialog")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .keyboardShortcuts([KeyboardShortcutAction(.escape) { close() }])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Add Entity")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(theme.editorColors.text)
            Text("Choose an entity bundle · Child of \(parentName)")
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 64, alignment: .leading)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Text("\u{E8B6}")
                .font(AdaEditorMaterialSymbolFont.font(size: 18))
                .foregroundColor(theme.editorColors.muted)
            TextField("Search bundles", text: $search)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
                .textFieldStyle(PlainTextFieldStyle())
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                .accessibilityIdentifier("AdaEditor.EntityPicker.Search")
            if !search.isEmpty {
                Button(
                    action: { search = "" },
                    label: {
                        Text("\u{E5CD}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 16))
                            .foregroundColor(theme.editorColors.muted)
                            .frame(width: 26, height: 26)
                    }
                )
                .buttonStyle(DefaultButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.background))
    }

    private func templateGrid(width: Float, height: Float) -> some View {
        let groups = EditorSceneEntityTemplateGroup.allCases.filter { group in
            group.templates.contains { $0.matches(search) }
        }
        let columns = groupedColumns(groups, width: width)
        return ScrollView(.vertical) {
            if groups.isEmpty {
                Text("No entity bundles match your search.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.muted)
                    .padding(20)
                    .accessibilityIdentifier("AdaEditor.EntityPicker.NoResults")
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { column in
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(column.element, id: \.self) { group in
                                templateGroup(group)
                            }
                        }
                        .frame(width: (width - 32 - Float(columns.count - 1) * 16) / Float(columns.count), alignment: .topLeading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func groupedColumns(
        _ groups: [EditorSceneEntityTemplateGroup],
        width: Float
    ) -> [[EditorSceneEntityTemplateGroup]] {
        let preferred: [[EditorSceneEntityTemplateGroup]]
        if width >= 720 {
            preferred = [[.general, .gameplay], [.twoD], [.threeD]]
        } else if width >= 480 {
            preferred = [[.general, .twoD], [.threeD, .gameplay]]
        } else {
            preferred = [EditorSceneEntityTemplateGroup.allCases]
        }
        return
            preferred
            .map { column in column.filter(groups.contains) }
            .filter { !$0.isEmpty }
    }

    private func templateGroup(_ group: EditorSceneEntityTemplateGroup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(group.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.editorColors.muted)
                RectangleShape().fill(theme.editorColors.border.opacity(0.6)).frame(height: 1)
            }
            .frame(height: 22)
            ForEach(group.templates.filter { $0.matches(search) }, id: \.self) { template in
                templateButton(template)
            }
        }
        .accessibilityIdentifier("AdaEditor.EntityPicker.Group.\(group.rawValue)")
    }

    private func templateButton(_ template: EditorSceneEntityTemplate) -> some View {
        Button {
            workbench.addSceneEntity(
                documentID: request.documentID,
                parentID: request.parentID,
                template: template
            )
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Text(template.icon)
                    .font(AdaEditorMaterialSymbolFont.font(size: 22))
                    .foregroundColor(template.tint)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangleShape(cornerRadius: 7).fill(template.tint.opacity(0.10)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.title)
                        .font(.system(size: 12))
                        .foregroundColor(theme.editorColors.text)
                        .lineLimit(1)
                    Text(template.detail)
                        .font(.system(size: 10))
                        .foregroundColor(theme.editorColors.muted)
                        .lineLimit(1)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .frame(height: 48)
        }
        .buttonStyle(EditorEntityTemplateButtonStyle(theme: theme))
        .accessibilityIdentifier("AdaEditor.EntityPicker.\(template.rawValue)")
    }

    private var footer: some View {
        HStack {
            Text("\(EditorSceneEntityTemplate.allCases.filter { $0.matches(search) }.count) bundles")
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.muted)
            Spacer()
            Button("Cancel", action: close)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.background))
                .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border, lineWidth: 1) }
                .accessibilityIdentifier("AdaEditor.EntityPicker.Cancel")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func close() {
        workbench.entityPickerRequest = nil
        dismiss()
    }
}

private struct EditorEntityTemplateButtonStyle: ButtonStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangleShape(cornerRadius: 6)
                    .fill(
                        configuration.state.isHighlighted || configuration.state.isSelected ? theme.editorColors.blue.opacity(0.18) : Color.clear
                    )
            )
    }
}

extension EditorSceneEntityTemplate {
    var icon: String {
        switch self {
        case .empty: "\u{E86F}"
        case .scriptable: "\u{E87B}"
        case .sceneInstance: "\u{F720}"
        case .camera2D,
            .camera3D:
            "\u{E3AF}"
        case .sprite: "\u{E3B6}"
        case .mesh2D,
            .model3D:
            "\u{E3A5}"
        case .tileMap: "\u{E8F1}"
        case .light2D,
            .directionalLight3D,
            .pointLight3D,
            .spotLight3D:
            "\u{E0F0}"
        case .ui: "\u{E871}"
        case .physicsBody2D,
            .physicsBody3D:
            "\u{E8B8}"
        }
    }

    var tint: Color {
        switch group {
        case .general: Color(red: 0.91, green: 0.73, blue: 0.30)
        case .twoD: Color(red: 0.35, green: 0.70, blue: 0.94)
        case .threeD: Color(red: 0.65, green: 0.55, blue: 0.94)
        case .gameplay: Color(red: 0.44, green: 0.75, blue: 0.62)
        }
    }
}
