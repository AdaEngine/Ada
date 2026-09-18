@_spi(AdaEngine) import AdaEngine

extension EditorInspectorSidebar {
    func compactActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.blue)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.blue.opacity(0.12)))
        }
        .buttonStyle(DefaultButtonStyle())
    }

    @ViewBuilder
    var addComponentPicker: some View {
        if let selectedEntity = viewModel.selectedEntity, !selectedEntity.addableComponents.isEmpty {
            Button(
                action: {
                    activeSceneFieldID = nil
                    viewModel.presentComponentPicker()
                },
                label: {
                    HStack(spacing: 6) {
                        Text("+").font(.system(size: 15))
                        Text("Add Component").font(.system(size: 11))
                        Spacer()
                        Text("\u{E5CC}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 16))
                    }
                    .foregroundColor(theme.editorColors.blue)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.blue.opacity(0.12)))
                    .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.blue.opacity(0.35), lineWidth: 1) }
                }
            )
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.Inspector.AddComponent")
        }
    }

    func scriptableObjectEditor(_ object: EditorInspectorSidebarViewModel.ScriptableObjectSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(object.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.text)
                Spacer()
                Button(
                    action: { viewModel.removeScriptableObjectRequested(object.identifier) },
                    label: {
                        Text("\u{E872}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 16))
                            .foregroundColor(.red)
                            .frame(width: 24, height: 24)
                    }
                )
                .buttonStyle(DefaultButtonStyle())
            }
            ForEach(object.fields, id: \.field.id) { field in
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(field.field.label)
                    fieldControl(
                        fieldID: "\(object.identifier).\(field.field.key)",
                        value: field.value,
                        kind: field.field.kind,
                        isEditable: field.field.isEditable,
                        scalarBinding: viewModel.scriptableObjectFieldBinding(identifier: object.identifier, field: field.field),
                        axisBinding: { _ in viewModel.scriptableObjectFieldBinding(identifier: object.identifier, field: field.field) }
                    )
                }
            }
        }
        .padding(.vertical, 6)
    }

    func addScriptableObjectButton(_ descriptor: EditorScriptableObjectDescriptor) -> some View {
        Button(
            action: { viewModel.addScriptableObjectRequested(descriptor) },
            label: {
                HStack(spacing: 6) {
                    Text("+")
                        .foregroundColor(theme.editorColors.purple)
                    Text(descriptor.name)
                        .foregroundColor(theme.editorColors.text)
                    Spacer()
                    Text(descriptor.sourcePath)
                        .foregroundColor(theme.editorColors.muted)
                        .lineLimit(1)
                }
                .font(.system(size: 10))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
            }
        )
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Inspector.AddScriptableObject.\(descriptor.identifier)")
    }
}

struct EditorAddComponentDialog: View {
    let viewModel: EditorInspectorSidebarViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var hoveredComponentTypeName: String?

    var body: some View {
        GeometryReader { geometry in
            let width = Swift.min(680, Swift.max(280, geometry.size.width - 48))
            let height = Swift.min(680, Swift.max(360, geometry.size.height - 48))

            ZStack(anchor: .center) {
                Color.black.opacity(0.62)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture {
                        close()
                    }

                VStack(alignment: .leading, spacing: 0) {
                    header
                    searchField
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)
                    componentList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    footer
                }
                .frame(width: width, height: height)
                .background(RoundedRectangleShape(cornerRadius: 14).fill(theme.editorColors.surfaceElevated))
                .overlay {
                    RoundedRectangleShape(cornerRadius: 14)
                        .stroke(theme.editorColors.border, lineWidth: 1)
                }
                .accessibilityIdentifier("AdaEditor.AddComponent.Dialog")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\u{E87B}")
                .font(AdaEditorMaterialSymbolFont.font(size: 24))
                .foregroundColor(theme.editorColors.blue)
                .frame(width: 36, height: 36)
                .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.blue.opacity(0.15)))

            VStack(alignment: .leading, spacing: 4) {
                Text("Add Component")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                Text(dialogDescription)
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(2)
            }
            Spacer()
            Button(action: close) {
                Text("\u{E5CD}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 20))
                    .foregroundColor(theme.editorColors.muted)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.background))
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.AddComponent.Close")
        }
        .padding(20)
    }

    private var dialogDescription: String {
        guard let selectedEntity = viewModel.selectedEntity else {
            return "Choose a component to add to the selected entity."
        }
        return "Choose a component to add to \(selectedEntity.name)."
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Text("\u{E8B6}")
                .font(AdaEditorMaterialSymbolFont.font(size: 18))
                .foregroundColor(theme.editorColors.muted)
            TextField("Search by name, category, or description", text: viewModel.componentSearchTextBinding)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
                .textFieldStyle(PlainTextFieldStyle())
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityIdentifier("AdaEditor.Inspector.ComponentSearch")
            if !viewModel.componentSearchText.isEmpty {
                Button(
                    action: { viewModel.componentSearchText = "" },
                    label: {
                        Text("\u{E5CD}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 16))
                            .foregroundColor(theme.editorColors.muted)
                            .frame(width: 26, height: 26)
                    }
                )
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.AddComponent.ClearSearch")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.background))
        .overlay {
            RoundedRectangleShape(cornerRadius: 8)
                .stroke(theme.editorColors.border.opacity(0.95), lineWidth: 1)
        }
        .accessibilityIdentifier("AdaEditor.AddComponent.SearchBar")
    }

    @ViewBuilder
    private var componentList: some View {
        let components = viewModel.addableComponents(matching: viewModel.componentSearchText)
        if components.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("No components found")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                Text("Try another name, category, or description.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("AdaEditor.AddComponent.EmptyState")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(components, id: \.typeName) { component in
                        componentRow(component)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
    }

    private func componentRow(_ component: EditorInspectorSidebarViewModel.AddableComponent) -> some View {
        EditorAddComponentRow(
            component: component,
            isHovered: hoveredComponentTypeName == component.typeName,
            onHover: { isHovered in
                hoveredComponentTypeName = isHovered ? component.typeName : nil
            },
            onAdd: {
                viewModel.addComponentRequested(component.typeName)
                close()
            }
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(viewModel.addableComponents(matching: viewModel.componentSearchText).count) available")
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.muted)
            Spacer()
            Button("Cancel", action: close)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.background))
                .overlay {
                    RoundedRectangleShape(cornerRadius: 7)
                        .stroke(theme.editorColors.border, lineWidth: 1)
                }
                .accessibilityIdentifier("AdaEditor.AddComponent.Cancel")
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
        .background(theme.editorColors.surface)
    }

    private func close() {
        viewModel.dismissComponentPicker()
        dismiss()
    }
}

private struct EditorAddComponentRow: View {
    let component: EditorInspectorSidebarViewModel.AddableComponent
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onAdd: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(
            action: onAdd,
            label: {
                content
                    .padding(.horizontal, 12)
                    .frame(minHeight: 64)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(rowBackground)
                    .overlay { rowBorder }
            }
        )
        .buttonStyle(DefaultButtonStyle())
        .onHover(perform: onHover)
        .accessibilityIdentifier("AdaEditor.Inspector.AddComponent.\(component.typeName)")
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 12) {
            componentIcon
            componentDescription
            Spacer()
            Text("+")
                .font(.system(size: 18))
                .foregroundColor(theme.editorColors.blue)
                .frame(width: 30, height: 30)
                .background(CircleShape().fill(theme.editorColors.blue.opacity(0.12)))
        }
    }

    private var componentIcon: some View {
        Text("\u{E87B}")
            .font(AdaEditorMaterialSymbolFont.font(size: 19))
            .foregroundColor(theme.editorColors.blue)
            .frame(width: 34, height: 34)
            .background(RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.blue.opacity(0.12)))
    }

    private var componentDescription: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(component.displayName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                Text(component.category)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.editorColors.blue)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(CapsuleShape().fill(theme.editorColors.blue.opacity(0.12)))
            }
            Text(component.description)
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(2)
        }
    }

    private var rowBackground: some View {
        RoundedRectangleShape(cornerRadius: 8)
            .fill(isHovered ? theme.editorColors.blue.opacity(0.12) : theme.editorColors.surface)
    }

    private var rowBorder: some View {
        RoundedRectangleShape(cornerRadius: 8)
            .stroke(isHovered ? theme.editorColors.blue.opacity(0.42) : theme.editorColors.border.opacity(0.75), lineWidth: 1)
    }
}
