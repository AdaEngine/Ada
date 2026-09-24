@_spi(AdaEngine) import AdaEngine

struct EditorInspectorSidebar: View {
    let viewModel: EditorInspectorSidebarViewModel

    @State var activeAssetFieldID: String?
    @State var assetSearchText = ""
    @State var colorFieldModes: [String: ColorFieldMode] = [:]
    @State var colorTextDrafts: [String: String] = [:]
    @State var activeSceneFieldID: String?
    @State var sceneSearchText = ""
    @State private var collapsedComponentTypeNames: Set<String> = []

    @Environment(\.metrics) private var metrics
    @Environment(\.theme) var theme

    var body: some View {
        ZStack(anchor: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                adaEditorInspectorTitle(theme: theme)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let runtimeSelection = viewModel.runtimeSelection {
                            inspectorSection("PLAY MODE · \(runtimeSelection.name.uppercased())") {
                                Text("Entity #\(runtimeSelection.id)")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.editorColors.muted)
                                Text("Live values · read only")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.editorColors.muted)
                            }
                            inspectorSection("COMPONENTS") {
                                ForEach(runtimeSelection.components, id: \.name) { component in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(component.name)
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(theme.editorColors.text)
                                        Text(component.value)
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.editorColors.muted)
                                            .lineLimit(3)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        } else if viewModel.isInspectingPlayMode {
                            inspectorSection("PLAY MODE") {
                                Text("Select a live entity from the Play toolbar to inspect its components.")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.editorColors.muted)
                                    .lineLimit(3)
                            }
                        } else if let selectedEntity = viewModel.selectedEntity {
                            inspectorSection(selectedEntity.name.uppercased()) {
                                Text(selectedEntity.editorID)
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.editorColors.muted)
                            }
                            inspectorSection("COMPONENTS") {
                                ForEach(selectedEntity.components, id: \.typeName) { component in
                                    componentEditor(component)
                                }
                                addComponentPicker
                            }
                            if !selectedEntity.scriptableObjects.isEmpty || !selectedEntity.addableScriptableObjects.isEmpty {
                                inspectorSection("SCRIPTABLE OBJECTS") {
                                    ForEach(selectedEntity.scriptableObjects, id: \.identifier) { object in
                                        scriptableObjectEditor(object)
                                    }
                                    ForEach(selectedEntity.addableScriptableObjects, id: \.identifier) { descriptor in
                                        addScriptableObjectButton(descriptor)
                                    }
                                }
                            }
                            inspectorSection("GIZMO") {
                                gizmoEditor(selectedEntity)
                            }
                        } else {
                            inspectorSection("SELECTION") {
                                Text("Click an entity in the scene or hierarchy to inspect it.")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.editorColors.muted)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            if activeSceneFieldID != nil {
                scenePickerPanel
                    .padding(.horizontal, 12)
                    .offset(y: 42)
                    .zIndex(20)
            }
        }
        .background(
            RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner)
                .fill(theme.editorColors.surfaceElevated)
        )
        .mask(RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundColor(theme.editorColors.blue)
            content()
        }
        .padding(12)
    }

    private func componentEditor(_ component: EditorInspectorSidebarViewModel.ComponentSection) -> some View {
        let isCollapsed = collapsedComponentTypeNames.contains(component.typeName)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button(action: { toggleComponentCollapsed(component.typeName) }) {
                    HStack(spacing: 5) {
                        Text(isCollapsed ? "\u{E5CC}" : "\u{E5CF}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 15))
                            .foregroundColor(theme.editorColors.muted)
                        Text(component.displayName)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(theme.editorColors.text)
                    }
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Inspector.ToggleComponent.\(component.typeName)")
                Spacer()
                if component.canRemove {
                    Button(action: { viewModel.removeComponentRequested(component.typeName) }) {
                        Text("\u{E872}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 16))
                            .foregroundColor(.red)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .accessibilityIdentifier("AdaEditor.Inspector.RemoveComponent.\(component.typeName)")
                }
            }

            if !isCollapsed {
                ForEach(component.fields, id: \.field.id) { field in
                    componentFieldRow(field)
                }
            }

            RectangleShape()
                .fill(theme.editorColors.border.opacity(0.7))
                .frame(height: 1)
                .padding(.top, 4)
        }
        .padding(.vertical, 6)
    }

    private func toggleComponentCollapsed(_ typeName: String) {
        if collapsedComponentTypeNames.contains(typeName) {
            collapsedComponentTypeNames.remove(typeName)
        } else {
            collapsedComponentTypeNames.insert(typeName)
        }
    }

    private func componentFieldRow(_ field: EditorInspectorSidebarViewModel.ComponentField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(field.field.label)
            if [EditorBuiltInComponentType.uiComponent, EditorBuiltInComponentType.companionPanel].contains(field.typeName), field.field.key == "path" {
                Button("Choose UI source…") { activeSceneFieldID = activeSceneFieldID == "ui-source" ? nil : "ui-source" }
                if activeSceneFieldID == "ui-source" {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.uiSourcePaths, id: \.self) { path in
                                Button(path) {
                                    viewModel.componentFieldBinding(typeName: field.typeName, field: field.field).wrappedValue = path
                                    activeSceneFieldID = nil
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
            if [EditorBuiltInComponentType.uiComponent, EditorBuiltInComponentType.companionPanel].contains(field.typeName), field.field.key == "scriptBindings" {
                scriptUIBindingsEditor(field)
            } else if [EditorBuiltInComponentType.physicsBody2D, EditorBuiltInComponentType.physicsBody3D].contains(field.typeName), field.field.key == "shapes" {
                EditorPhysicsShapesField(
                    text: viewModel.componentFieldBinding(typeName: field.typeName, field: field.field),
                    is3D: field.typeName == EditorBuiltInComponentType.physicsBody3D
                )
                .id(viewModel.selectedEntity?.editorID)
            } else {
                fieldControl(
                    fieldID: "\(field.typeName).\(field.field.key)",
                    value: field.value,
                    kind: field.field.kind,
                    isEditable: field.field.isEditable,
                    scalarBinding: viewModel.componentFieldBinding(typeName: field.typeName, field: field.field),
                    axisBinding: { viewModel.componentVectorAxisBinding(typeName: field.typeName, field: field.field, axisIndex: $0) }
                )
            }
        }
    }

    func fieldLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundColor(theme.editorColors.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func fieldControl(
        fieldID: String,
        value: String,
        kind: EditorComponentFieldKind,
        isEditable: Bool,
        scalarBinding: Binding<String>,
        axisBinding: @escaping (Int) -> Binding<String>
    ) -> some View {
        if let axes = axisLabels(for: kind) {
            vectorField(fieldID: fieldID, axes: axes, value: value, isEditable: isEditable, axisBinding: axisBinding)
        } else if case .bool = kind, isEditable {
            boolField(text: scalarBinding)
                .accessibilityIdentifier("AdaEditor.Inspector.Bool.\(fieldID)")
        } else if case let .enumeration(cases) = kind, isEditable {
            EditorEnumField(cases: cases, selection: scalarBinding, accessibilityID: "AdaEditor.Inspector.Enum.\(fieldID)")
        } else if case .color = kind, isEditable {
            colorField(fieldID: fieldID, value: value, text: scalarBinding)
        } else if case .assetReference = kind, isEditable {
            assetReferenceField(fieldID: fieldID, value: value, text: scalarBinding)
        } else if case .sceneReference = kind, isEditable {
            sceneReferenceField(fieldID: fieldID, value: value)
        } else if isEditable {
            editorTextField(text: scalarBinding)
        } else {
            readonlyField(value)
        }
    }

    private func vectorField(
        fieldID: String,
        axes: [String],
        value: String,
        isEditable: Bool,
        axisBinding: @escaping (Int) -> Binding<String>
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(axes.indices), id: \.self) { index in
                vectorAxisField(
                    label: axes[index],
                    value: vectorDisplayValue(from: value, index: index),
                    isEditable: isEditable,
                    text: axisBinding(index)
                )
                .accessibilityIdentifier("AdaEditor.Inspector.Axis.\(fieldID).\(axes[index])")
            }
        }
        .frame(height: 32)
        .frame(maxWidth: .infinity)
    }

    private func vectorAxisField(label: String, value: String, isEditable: Bool, text: Binding<String>) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 24, height: 32)
                .background(RectangleShape().fill(axisColor(for: label)))
            if isEditable {
                TextField("", text: text)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(.horizontal, 7)
            } else {
                Text(value)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.editorColors.muted)
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 72, maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
        .background(RoundedRectangleShape(cornerRadius: 5).fill(isEditable ? theme.editorColors.surface : theme.editorColors.surfaceElevated))
        .mask(RoundedRectangleShape(cornerRadius: 5))
        .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(theme.editorColors.border.opacity(0.92), lineWidth: 1) }
    }

    func editorTextField(text: Binding<String>) -> some View {
        TextField("", text: text)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(theme.editorColors.text)
            .textFieldStyle(PlainTextFieldStyle())
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
            .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(theme.editorColors.border.opacity(0.92), lineWidth: 1) }
    }

    private func axisColor(for label: String) -> Color {
        switch label {
        case "X": Color(red: 0.78, green: 0.24, blue: 0.28)
        case "Y": Color(red: 0.24, green: 0.60, blue: 0.31)
        case "Z": Color(red: 0.22, green: 0.43, blue: 0.82)
        case "W": Color(red: 0.57, green: 0.32, blue: 0.76)
        default: theme.editorColors.muted
        }
    }

    private func boolField(text: Binding<String>) -> some View {
        let isOn = text.wrappedValue == "true"
        return Button(action: {
            text.wrappedValue = text.wrappedValue == "true" ? "false" : "true"
        }) {
            HStack(spacing: 8) {
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 11))
                    .foregroundColor(isOn ? theme.editorColors.text : theme.editorColors.muted)
                Spacer()
                ZStack(anchor: isOn ? .trailing : .leading) {
                    RoundedRectangleShape(cornerRadius: 8)
                        .fill(isOn ? theme.editorColors.blue : theme.editorColors.border)
                        .frame(width: 30, height: 16)
                    CircleShape()
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                        .padding(.horizontal, 2)
                        .accessibilityIdentifier("AdaEditor.Inspector.ToggleThumb")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
            .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(theme.editorColors.border.opacity(0.92), lineWidth: 1) }
        }
        .buttonStyle(DefaultButtonStyle())
    }

    private func readonlyField(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11))
            .foregroundColor(theme.editorColors.muted)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surfaceElevated))
            .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(theme.editorColors.border.opacity(0.60), lineWidth: 1) }
    }

    private func axisLabels(for kind: EditorComponentFieldKind) -> [String]? {
        switch kind {
        case .vector2:
            return ["X", "Y"]
        case .vector3:
            return ["X", "Y", "Z"]
        case .vector4:
            return ["X", "Y", "Z", "W"]
        default:
            return nil
        }
    }

    private func vectorDisplayValue(from value: String, index: Int) -> String {
        let components =
            value
            .split { $0 == "," || $0 == " " || $0 == "\t" }
            .map { String($0) }
        guard components.indices.contains(index) else {
            return "0"
        }
        return components[index]
    }

    private func gizmoEditor(_ selectedEntity: EditorInspectorSidebarViewModel.SelectedEntity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if selectedEntity.hasExplicitGizmo {
                HStack {
                    Button(action: { viewModel.toggleGizmoEnabled() }) {
                        Text((selectedEntity.gizmo?.isEnabled ?? false) ? "Enabled" : "Disabled")
                            .font(.system(size: 11))
                            .foregroundColor(theme.editorColors.text)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.blue.opacity(0.16)))
                    }
                    Spacer()
                    Button(action: { viewModel.removeComponentRequested(EditorSceneYAMLDocument.editorGizmoComponentName) }) {
                        Text("\u{E872}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 16))
                            .foregroundColor(.red)
                            .frame(width: 24, height: 24)
                    }
                    .accessibilityIdentifier("AdaEditor.Inspector.RemoveGizmo")
                }
                .buttonStyle(DefaultButtonStyle())

                TextField("Name", text: viewModel.gizmoNameBinding)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.surface))
                    .overlay { RoundedRectangleShape(cornerRadius: 4).stroke(theme.editorColors.border, lineWidth: 1) }

                HStack(spacing: 4) {
                    ForEach(EditorGizmoKind.allCases, id: \.rawValue) { kind in
                        gizmoKindButton(kind, active: selectedEntity.gizmo?.kind == kind)
                    }
                }
            } else {
                Button(action: { viewModel.addGizmo() }) {
                    Text("Add Gizmo")
                        .font(.system(size: 11))
                        .foregroundColor(theme.editorColors.blue)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.blue.opacity(0.12)))
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Inspector.AddGizmo")
            }
        }
    }

    private func gizmoKindButton(_ kind: EditorGizmoKind, active: Bool) -> some View {
        Button(action: { viewModel.setGizmoKind(kind) }) {
            Text(kind.rawValue)
                .font(.system(size: 10))
                .foregroundColor(active ? theme.editorColors.text : theme.editorColors.muted)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(RoundedRectangleShape(cornerRadius: 4).fill(active ? theme.editorColors.purple.opacity(0.18) : theme.editorColors.surface))
        }
        .buttonStyle(DefaultButtonStyle())
    }

    private func shortComponentName(_ componentName: String) -> String {
        componentName.components(separatedBy: ".").last ?? componentName
    }
}
