@_spi(AdaEngine) import AdaEngine

struct EditorTileMapSidebar: View {
    let model: EditorTileMapEditorModel
    @State private var layerName = ""
    @State private var pendingColorRemoval: Int?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            layers
                .padding(12)
            RectangleShape().fill(theme.editorColors.border).frame(height: 1)
            palette
                .padding(12)
                .frame(maxHeight: .infinity)
        }
        .background(theme.editorColors.surfaceElevated)
    }

    private var layers: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Layers", detail: "\(model.layers.count)")
            ScrollView(showsIndicators: true) {
                VStack(spacing: 4) {
                    // Topmost painted layer appears first, matching the resulting image.
                    ForEach(Array(model.layers.indices.reversed()), id: \.self) { index in
                        layerRow(index)
                    }
                }
            }
            .frame(height: min(168, Float(model.layers.count) * 42))
            HStack(spacing: 5) {
                action("Add", id: "AddLayer") { model.addLayer() }
                action("Remove", id: "RemoveLayer") { model.removeSelectedLayer() }.disabled(model.layers.count <= 1)
                Spacer(minLength: 0)
                action("Raise", id: "MoveLayerUp") { model.moveSelectedLayer(by: 1) }
                    .disabled(model.selectedLayer == model.layers.count - 1)
                action("Lower", id: "MoveLayerDown") { model.moveSelectedLayer(by: -1) }.disabled(model.selectedLayer == 0)
            }
            HStack(spacing: 6) {
                TextField(model.layers[model.selectedLayer].name, text: $layerName)
                    .font(.system(size: 12))
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(8)
                    .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.background))
                action("Rename", id: "RenameLayer") {
                    model.renameSelectedLayer(layerName)
                    layerName = ""
                }.disabled(layerName.isEmpty)
            }
        }
    }

    private func layerRow(_ index: Int) -> some View {
        let layer = model.layers[index]
        let selected = model.selectedLayer == index
        return HStack(spacing: 6) {
            Button(action: { model.selectLayer(index); layerName = "" }) {
                HStack(spacing: 8) {
                    symbol("\u{E3B6}", color: selected ? theme.editorColors.blue : theme.editorColors.muted)
                    Text(layer.name)
                        .font(.system(size: 12, weight: selected ? .bold : .regular))
                        .foregroundColor(theme.editorColors.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(layer.cells.count)")
                        .font(.system(size: 11))
                        .foregroundColor(theme.editorColors.muted)
                }
                .padding(.horizontal, 8)
                .frame(height: 38)
            }
            .buttonStyle(EditorTileMapButtonStyle(theme: theme))
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("AdaEditor.TileMapEditor.Layer.\(index)")
            Button(action: { model.selectLayer(index); model.toggleSelectedLayer() }) {
                symbol(layer.isEnabled ? "\u{E8F4}" : "\u{E8F5}", color: theme.editorColors.muted)
                    .frame(width: 28, height: 38)
            }
            .buttonStyle(EditorTileMapButtonStyle(theme: theme))
            .accessibilityIdentifier(selected ? "AdaEditor.TileMapEditor.ToggleLayer" : "AdaEditor.TileMapEditor.Visibility.\(index)")
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(selected ? theme.editorColors.blue.opacity(0.14) : theme.editorColors.surface))
        .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(selected ? theme.editorColors.blue.opacity(0.7) : .clear, lineWidth: 1) }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Tiles", detail: "\(model.paletteCount)")
            HStack(spacing: 6) {
                action("Link source…", id: "LinkTileSet") { model.presentTileSetPicker() }
                if model.map.tileSetReference == nil {
                    action("New source", id: "NewTileSet") { model.createTileSet() }
                } else {
                    action("Refresh", id: "RefreshTileSet") { model.refreshTileSet() }
                }
            }
            Text(model.map.tileSetReference == nil ? "Choose a color below, or link a tile source for textures." : model.tileSetStatus)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(2)
            Text(model.paletteCount > 0 ? "Brush: \(model.paletteLabel(at: model.selectedColor))" : "No tiles yet")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(theme.editorColors.text)
                .lineLimit(1)
            if pendingColorRemoval == model.selectedColor && model.canRemoveSelectedColor {
                HStack(spacing: 6) {
                    action("Delete on all layers", id: "ConfirmRemoveColor") {
                        model.removeSelectedColor()
                        pendingColorRemoval = nil
                    }
                    action("Cancel", id: "CancelRemoveColor") { pendingColorRemoval = nil }
                }
            } else {
                action("Remove color…", id: "RemoveColor") { pendingColorRemoval = model.selectedColor }
                    .disabled(!model.canRemoveSelectedColor)
            }
            Text("Erase cells: eraser tool or right-drag. Remove color also clears its cells on all layers.")
                .font(.system(size: 11)).foregroundColor(theme.editorColors.muted).lineLimit(3)
            GeometryReader { geometry in
                // Leave space for the scroll indicator while filling the palette width.
                let availableWidth = max(0, geometry.size.width - 12)
                let columns = max(1, Int((availableWidth + 6) / 86))
                let tileWidth = max(0, (availableWidth - Float(columns - 1) * 6) / Float(columns))
                ScrollView(showsIndicators: true) {
                    LazyVStack(
                        0..<((model.paletteCount + columns - 1) / columns),
                        id: \.self,
                        alignment: .leading,
                        spacing: 6,
                        estimatedRowHeight: 80,
                        overscan: 2
                    ) { row in
                        HStack(spacing: 6) {
                            ForEach(0..<columns, id: \.self) { column in
                                let index = row * columns + column
                                if index < model.paletteCount {
                                    tile(index, width: tileWidth)
                                } else {
                                    Color.clear.frame(width: tileWidth, height: 80)
                                }
                            }
                        }
                    }
                    .frame(width: availableWidth, alignment: .leading)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("AdaEditor.TileMapEditor.Palette")
            HStack(spacing: 6) {
                TextField("Hex color", text: Binding(get: { model.newColorHex }, set: { model.newColorHex = $0 }))
                    .font(.system(size: 12))
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(8)
                    .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.background))
                action("Add color", id: "AddColor") { model.addColor() }
            }
        }
    }

    private func tile(_ index: Int, width: Float) -> some View {
        let selected = model.selectedColor == index && model.tool == .paint
        return Button(action: { model.selectedColor = index; model.tool = .paint }) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangleShape(cornerRadius: 4).fill(model.paletteColor(at: index))
                    EditorTileMapPalettePreview(model: model, index: index)
                }
                .frame(width: 48, height: 48)
                HStack(spacing: 4) {
                    if selected { symbol("\u{E5CA}", color: theme.editorColors.blue).frame(width: 12, height: 12) }
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: selected ? .bold : .regular))
                        .foregroundColor(theme.editorColors.text)
                }
            }
            .frame(width: width, height: 80)
        }
        .buttonStyle(EditorTileMapButtonStyle(theme: theme))
        .background(RoundedRectangleShape(cornerRadius: 6).fill(selected ? theme.editorColors.blue.opacity(0.16) : theme.editorColors.surface))
        .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(selected ? theme.editorColors.blue : theme.editorColors.border, lineWidth: selected ? 2 : 1) }
        .accessibilityIdentifier("AdaEditor.TileMapEditor.Color.\(index)")
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(theme.editorColors.text)
            Spacer()
            Text(detail).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
        }
    }

    private func symbol(_ value: String, color: Color) -> some View {
        Text(value).font(AdaEditorMaterialSymbolFont.font(size: 17)).foregroundColor(color)
    }

    private func action(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 7)
                .frame(minHeight: 28)
        }
        .buttonStyle(EditorTileMapButtonStyle(theme: theme))
        .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
        .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(theme.editorColors.border, lineWidth: 1) }
        .accessibilityIdentifier("AdaEditor.TileMapEditor.\(id)")
    }
}

private struct EditorTileMapPalettePreview: View {
    let model: EditorTileMapEditorModel
    let index: Int

    var body: some View {
        // Texture storage is not observed; only palette reloads replace it.
        // Painting and changing the selection keep these GPU resources intact.
        _ = model.paletteRevision
        let texture = model.texture(at: index)
        return Canvas { context, size in
            if let texture {
                context.drawRect(Rect(origin: .zero, size: size), texture: texture, color: .white)
            }
        }
    }
}

struct EditorTileMapButtonStyle: ButtonStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.blue.opacity(configuration.isPressed ? 0.2 : (configuration.isHighlighted ? 0.1 : 0))))
    }
}
