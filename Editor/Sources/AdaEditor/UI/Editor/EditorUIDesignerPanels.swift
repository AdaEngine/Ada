@_spi(AdaEngine) import AdaEngine

extension EditorUISceneEditor {
    var designerLibrary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(["Components", "Layers"], id: \.self) { tab in
                    Button(tab) { libraryTab = tab }
                        .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, selected: libraryTab == tab))
                        .accessibilityIdentifier("AdaEditor.UIScene.Library.\(tab)")
                }
                Spacer()
            }
            .frame(height: 32).padding(10)
            panelDivider
            if libraryTab == "Components" {
                AnyView(componentLibrary).frame(maxHeight: .infinity)
            } else {
                AnyView(layerLibrary).frame(maxHeight: .infinity)
            }
        }
        .background(theme.editorColors.surface)
        .accessibilityIdentifier("AdaEditor.UIScene.Library")
    }

    var componentLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorUIDesignerField(placeholder: "Find component…", text: Binding(get: { model.search }, set: { model.search = $0 }))
                .accessibilityIdentifier("AdaEditor.UIScene.ComponentSearch")
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if model.palette.isEmpty {
                        Text("No matching components").foregroundColor(theme.editorColors.muted).font(.system(size: 12)).padding(.vertical, 12)
                    }
                    ForEach(["Layout", "Content", "Controls", "Drawing", "Advanced"], id: \.self) { category in
                        let items = model.palette.filter { EditorUIDesignerSymbols.category($0.id) == category }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                sectionTitle(category, detail: String(items.count)).padding(.horizontal, 6)
                                ForEach(items) { signature in
                                    Button {
                                        model.add(signature.id, selectingNewNode: false)
                                    } label: {
                                        HStack(spacing: 10) {
                                            symbol(EditorUIDesignerSymbols.icon(signature.id))
                                                .foregroundColor(theme.editorColors.muted)
                                            Text(signature.name).lineLimit(1)
                                            Spacer()
                                            symbol("\u{E145}", size: 12).foregroundColor(theme.editorColors.muted.opacity(0.6))
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .disabled(model.isReadOnly)
                                    .accessibilityIdentifier("AdaEditor.UIScene.Add.\(signature.id)")
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            Text("Adding to \(model.selectedNode?.type ?? "selected layer")")
                .font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
        }
        .padding(10)
    }

    var layerLibrary: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Document", detail: "\(layerCount) layers").padding(.horizontal, 8)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.node.id) { row in
                        layerRow(row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            panelDivider
            HStack(spacing: 4) {
                iconButton("\u{E5D8}", title: "Layer.Up") { model.reorder(-1) }
                iconButton("\u{E5DB}", title: "Layer.Down") { model.reorder(1) }
                Spacer()
                iconButton("\u{E14D}", title: "Layer.Duplicate", action: model.duplicateSelected)
                iconButton("\u{E872}", title: "Layer.Delete", action: model.removeSelected)
            }
            .disabled(model.isReadOnly || model.selectedID == model.document.root.id)
            Text("Wrap selection in").font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(["VStack", "HStack", "ZStack", "Grid"], id: \.self) { type in
                        Button(type) { model.wrap(type) }
                            .accessibilityIdentifier("AdaEditor.UIScene.Wrap.\(type)")
                    }
                }
                .disabled(model.isReadOnly)
            }
        }
        .padding(10)
    }

    var designerInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            adaEditorInspectorTitle(theme: theme)
            if let node = model.selectedNode, let signature = model.signature(for: node) {
                HStack(spacing: 10) {
                    symbol(EditorUIDesignerSymbols.icon(node.type), size: 20)
                        .foregroundColor(theme.editorColors.blue).padding(8)
                        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.blue.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(signature.name).font(.system(size: 15, weight: .semibold))
                        Text(node.id == model.document.root.id ? "Root container" : "Selected layer")
                            .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                    }
                    Spacer()
                }
                .padding(14).frame(height: 76)
                panelDivider
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        if node.type == "UI" {
                            Button("Open UI source") { model.openNestedUI() }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            sectionTitle("Properties", detail: String(signature.parameters.count))
                            if signature.parameters.isEmpty {
                                Text("This component has no properties.").font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                            }
                            ForEach(signature.parameters, id: \.name) { parameter in
                                parameterEditor(parameter, argument: node.arguments[parameter.name]) { argument in
                                    model.edit { document in
                                        EditorUISceneModel.modify(&document.root, id: node.id) { $0.arguments[parameter.name] = argument }
                                    }
                                }
                            }
                            ForEach(signature.actions, id: \.name) { action in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(action.name).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                                    EditorUIDesignerField(
                                        placeholder: "Handler name",
                                        text: Binding(
                                            get: { model.selectedNode?.actions[action.name] ?? "" },
                                            set: { value in model.updateSelected { $0.actions[action.name] = value.isEmpty ? nil : value } }
                                        )
                                    )
                                }
                            }
                        }
                        panelDivider
                        modifiersSection(node)
                        if node.id == model.document.root.id {
                            panelDivider
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    showsInputs.toggle()
                                } label: {
                                    HStack {
                                        symbol(showsInputs ? "\u{E5CF}" : "\u{E5CC}", size: 14)
                                        Text("Inputs & actions").font(.system(size: 12, weight: .semibold))
                                        Spacer()
                                        Text(String(model.document.inputs.count + model.document.actions.count)).foregroundColor(theme.editorColors.muted)
                                    }
                                }
                                .accessibilityIdentifier("AdaEditor.UIScene.Inputs.Toggle")
                                if showsInputs {
                                    inputDeclarations
                                }
                            }
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .disabled(model.isReadOnly)
            } else {
                Text("Select a layer to inspect").foregroundColor(theme.editorColors.muted).padding(16)
                Spacer()
            }
        }
        .textFieldStyle(EditorUIDesignerInspectorFieldStyle(colors: theme.editorColors))
        .background(theme.editorColors.surfaceElevated)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("AdaEditor.UIScene.Inspector")
    }

    func modifiersSection(_ node: UINodeDescription) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Modifiers", detail: String(node.modifiers.count))
            if node.modifiers.isEmpty {
                Text("Add padding, color or a frame to style this layer.")
                    .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            }
            ForEach(node.modifiers) { modifier in modifierEditor(modifier) }
            Button {
                if let present = model.onPresentModifierPicker {
                    present(node.id)
                } else {
                    modifierPickerNodeID = node.id
                }
            } label: {
                HStack {
                    symbol("\u{E145}", size: 14)
                    Text("Add modifier")
                    Spacer()
                }
            }
            .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, bordered: true))
            .accessibilityIdentifier("AdaEditor.UIScene.Modifiers.Toggle")
        }
    }
}

private struct EditorUIDesignerInspectorFieldStyle: TextFieldStyle {
    let colors: EditorThemeColors
    func _body(configuration: TextField) -> some View {
        PlainTextFieldStyle()._body(configuration: configuration)
            .font(.system(size: 12)).foregroundColor(colors.text)
            .padding(.horizontal, 6).frame(height: 30)
            .background(RoundedRectangleShape(cornerRadius: 6).fill(colors.surfaceElevated))
            .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(colors.border.opacity(0.6), lineWidth: 1) }
    }
}
