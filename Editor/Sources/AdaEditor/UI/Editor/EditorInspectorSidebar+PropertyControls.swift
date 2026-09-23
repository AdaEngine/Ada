@_spi(AdaEngine) import AdaEngine

extension EditorInspectorSidebar {
    func colorField(fieldID: String, value: String, text: Binding<String>) -> some View {
        let colorValue = EditorInspectorColorValue(value)
        let mode = colorFieldModes[fieldID] ?? .rgba
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                colorPickerSwatch(fieldID: fieldID, value: colorValue, text: text)
                editorTextField(text: colorTextBinding(fieldID: fieldID, mode: mode, value: colorValue, text: text))
            }
            HStack(spacing: 4) {
                colorModeButton(.rgba, fieldID: fieldID, selectedMode: mode)
                colorModeButton(.hex, fieldID: fieldID, selectedMode: mode)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    func colorPreview(from value: String) -> Color {
        let components =
            value
            .split { $0 == "," || $0 == " " || $0 == "\t" }
            .map { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        return Color(
            red: components.indices.contains(0) ? components[0] : 0,
            green: components.indices.contains(1) ? components[1] : 0,
            blue: components.indices.contains(2) ? components[2] : 0,
            alpha: components.indices.contains(3) ? components[3] : 1
        )
    }

    @ViewBuilder
    func colorPickerSwatch(
        fieldID: String,
        value: EditorInspectorColorValue,
        text: Binding<String>
    ) -> some View {
        #if (canImport(AppKit) && os(macOS)) || (canImport(UIKit) && os(iOS))
            Button(action: {
                EditorPlatformColorPicker.present(value: value) { updatedValue in
                    colorTextDrafts[fieldID] = nil
                    text.wrappedValue = updatedValue.rgbaString
                }
            }) {
                RectangleShape()
                    .fill(colorPreview(from: value.rgbaString))
                    .frame(width: 30, height: 28)
                    .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(theme.editorColors.border.opacity(0.92), lineWidth: 1) }
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.Inspector.ColorPicker.\(fieldID)")
        #else
            RectangleShape()
                .fill(colorPreview(from: value.rgbaString))
                .frame(width: 30, height: 28)
                .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(theme.editorColors.border.opacity(0.92), lineWidth: 1) }
        #endif
    }

    func colorTextBinding(
        fieldID: String,
        mode: ColorFieldMode,
        value: EditorInspectorColorValue,
        text: Binding<String>
    ) -> Binding<String> {
        Binding(
            get: {
                if let draft = colorTextDrafts[fieldID] {
                    return draft
                }
                return mode == .rgba ? value.rgbaString : value.hexString
            },
            set: { updatedText in
                colorTextDrafts[fieldID] = updatedText
                let updatedValue =
                    mode == .rgba
                    ? EditorInspectorColorValue(rgbaText: updatedText)
                    : EditorInspectorColorValue(hexText: updatedText)
                guard let updatedValue else {
                    return
                }
                text.wrappedValue = updatedValue.rgbaString
            }
        )
    }

    func colorModeButton(_ mode: ColorFieldMode, fieldID: String, selectedMode: ColorFieldMode) -> some View {
        Button(action: {
            colorFieldModes[fieldID] = mode
            colorTextDrafts[fieldID] = nil
        }) {
            Text(mode.title)
                .font(.system(size: 9))
                .foregroundColor(mode == selectedMode ? theme.editorColors.text : theme.editorColors.muted)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(
                    RoundedRectangleShape(cornerRadius: 4)
                        .fill(mode == selectedMode ? theme.editorColors.blue.opacity(0.22) : theme.editorColors.surface)
                )
        }
        .buttonStyle(DefaultButtonStyle())
    }

    func assetReferenceField(fieldID: String, value: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: {
                activeAssetFieldID = activeAssetFieldID == fieldID ? nil : fieldID
                assetSearchText = ""
            }) {
                HStack(spacing: 7) {
                    Text("\u{E3F4}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 17))
                        .foregroundColor(theme.editorColors.purple)
                    Text(value.isEmpty ? (fieldID.hasSuffix(".map") ? "Choose tile map…" : "Choose texture…") : value)
                        .font(.system(size: 10))
                        .foregroundColor(value.isEmpty ? theme.editorColors.muted : theme.editorColors.text)
                        .lineLimit(1)
                    Spacer()
                    Text("\u{E8B6}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 15))
                        .foregroundColor(theme.editorColors.muted)
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
                .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(theme.editorColors.border.opacity(0.92), lineWidth: 1) }
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.Inspector.AssetReference.\(fieldID)")
            .overlay {
                #if canImport(AppKit) && os(macOS)
                    EditorInspectorTextureDropTarget(
                        onClick: {
                            activeAssetFieldID = activeAssetFieldID == fieldID ? nil : fieldID
                            assetSearchText = ""
                        },
                        onDrop: { url in
                            let asset = fieldID.hasSuffix(".map")
                                ? viewModel.tileMapAssets.first(where: { $0.absolutePath == url.path })
                                : viewModel.textureAsset(droppedFileURL: url)
                            guard let asset else {
                                return
                            }
                            text.wrappedValue = asset.reference
                            activeAssetFieldID = nil
                        }
                    )
                #endif
            }

            if activeAssetFieldID == fieldID {
                assetPicker(text: text, tileMaps: fieldID.hasSuffix(".map"))
            }
        }
    }

    func sceneReferenceField(fieldID: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: {
                activeSceneFieldID = activeSceneFieldID == fieldID ? nil : fieldID
                viewModel.dismissComponentPicker()
                sceneSearchText = ""
            }) {
                HStack(spacing: 7) {
                    Text("\u{F720}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 17))
                        .foregroundColor(theme.editorColors.blue)
                    Text(value.isEmpty ? "Choose scene prefab…" : value)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(value.isEmpty ? theme.editorColors.muted : theme.editorColors.text)
                        .lineLimit(1)
                    Spacer()
                    Text("\u{E8B6}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 15))
                        .foregroundColor(theme.editorColors.muted)
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
                .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(theme.editorColors.border.opacity(0.92), lineWidth: 1) }
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.Inspector.SceneReference.\(fieldID)")
        }
    }

    @ViewBuilder
    var scenePickerPanel: some View {
        if let activeSceneFieldID,
            let field = viewModel.selectedEntity?.components
                .flatMap(\.fields)
                .first(where: { activeSceneFieldID == "\($0.typeName).\($0.field.key)" }) {
            scenePicker(text: viewModel.componentFieldBinding(typeName: field.typeName, field: field.field))
        }
    }

    func scenePicker(text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("Search project scenes", text: Binding(get: { sceneSearchText }, set: { sceneSearchText = $0 }))
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.background))
                .textFieldStyle(PlainTextFieldStyle())
                .accessibilityIdentifier("AdaEditor.Inspector.SceneSearch")
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Button(action: {
                        text.wrappedValue = ""
                        activeSceneFieldID = nil
                    }) {
                        HStack(spacing: 6) {
                            Text("\u{E14C}")
                                .font(AdaEditorMaterialSymbolFont.font(size: 15))
                                .foregroundColor(theme.editorColors.muted)
                            Text("None")
                                .font(.system(size: 10))
                                .foregroundColor(theme.editorColors.text)
                            Spacer()
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                    }
                    .buttonStyle(DefaultButtonStyle())
                    if viewModel.sceneAssets(matching: sceneSearchText).isEmpty {
                        Text("No scene assets found in this project.")
                            .font(.system(size: 9))
                            .foregroundColor(theme.editorColors.muted)
                            .padding(6)
                    } else {
                        ForEach(viewModel.sceneAssets(matching: sceneSearchText), id: \.id) { scene in
                            Button(action: {
                                text.wrappedValue = scene.reference
                                activeSceneFieldID = nil
                            }) {
                                HStack(spacing: 6) {
                                    Text("\u{F720}")
                                        .font(AdaEditorMaterialSymbolFont.font(size: 15))
                                        .foregroundColor(theme.editorColors.blue)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(scene.name).font(.system(size: 10, weight: .bold)).foregroundColor(theme.editorColors.text)
                                        Text(scene.reference).font(.system(size: 9)).foregroundColor(theme.editorColors.muted).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 6)
                                .frame(height: 32)
                            }
                            .buttonStyle(DefaultButtonStyle())
                            .accessibilityIdentifier("AdaEditor.Inspector.SceneAsset.\(scene.reference)")
                        }
                    }
                }
            }
            .frame(height: 126)
        }
        .padding(6)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surfaceElevated))
        .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border.opacity(0.65), lineWidth: 1) }
    }

    func assetPicker(text: Binding<String>, tileMaps: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(tileMaps ? "Search project tile maps" : "Search project textures", text: Binding(get: { assetSearchText }, set: { assetSearchText = $0 }))
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.background))
                .textFieldStyle(PlainTextFieldStyle())
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Button(action: {
                        text.wrappedValue = ""
                        activeAssetFieldID = nil
                    }) {
                        HStack(spacing: 6) {
                            Text("\u{E14C}")
                                .font(AdaEditorMaterialSymbolFont.font(size: 15))
                                .foregroundColor(theme.editorColors.muted)
                            Text("None")
                                .font(.system(size: 10))
                                .foregroundColor(theme.editorColors.text)
                            Spacer()
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                    }
                    .buttonStyle(DefaultButtonStyle())
                    if (tileMaps ? viewModel.tileMapAssets(matching: assetSearchText) : viewModel.textureAssets(matching: assetSearchText)).isEmpty {
                        Text(tileMaps ? "No tile maps found in this project." : "No image assets found in this project.")
                            .font(.system(size: 9))
                            .foregroundColor(theme.editorColors.muted)
                            .padding(6)
                    } else {
                        ForEach(tileMaps ? viewModel.tileMapAssets(matching: assetSearchText) : viewModel.textureAssets(matching: assetSearchText), id: \.id) { asset in
                            Button(action: {
                                text.wrappedValue = asset.reference
                                activeAssetFieldID = nil
                            }) {
                                HStack(spacing: 6) {
                                    Text("\u{E3F4}")
                                        .font(AdaEditorMaterialSymbolFont.font(size: 15))
                                        .foregroundColor(theme.editorColors.purple)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(asset.name).font(.system(size: 10)).foregroundColor(theme.editorColors.text)
                                        Text(asset.reference).font(.system(size: 9)).foregroundColor(theme.editorColors.muted).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 6)
                                .frame(height: 32)
                            }
                            .buttonStyle(DefaultButtonStyle())
                        }
                    }
                }
            }
            .frame(height: 126)
        }
        .padding(6)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surfaceElevated))
        .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border.opacity(0.65), lineWidth: 1) }
    }
}
