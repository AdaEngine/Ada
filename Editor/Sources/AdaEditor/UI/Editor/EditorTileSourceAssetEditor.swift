@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorTileSourceAssetEditor: View {
    let document: EditorAssetDocument
    @State private var model: EditorTileSourceEditorModel
    @Environment(\.theme) private var theme

    init(document: EditorAssetDocument, model: EditorTileSourceEditorModel? = nil) {
        self.document = document
        self._model = State(initialValue: model ?? EditorTileSourceEditorModel(document: document))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(model.status)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.editorColors.background)
        .accessibilityIdentifier("AdaEditor.TileSourceEditor")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(document.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(theme.editorColors.text)
            Spacer()
            action("−", id: "ZoomOut") { model.zoom = max(0.25, model.zoom / 1.5) }
            Text("\(Int(model.zoom * 100))%")
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.muted)
            action("+", id: "ZoomIn") { model.zoom = min(16, model.zoom * 1.5) }
            action(model.showGrid ? "Hide grid" : "Show grid", id: "Grid") { model.showGrid.toggle() }
            action("Reload", id: "Reload") { model.reload() }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if !model.sources.isEmpty {
            GeometryReader { geometry in
                let columns = max(1, Int(geometry.size.width / 252))
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(0..<((model.sources.count + columns - 1) / columns), id: \.self) { row in
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(row * columns..<min((row + 1) * columns, model.sources.count), id: \.self) { index in
                                    sourceCard(at: index)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .background(theme.editorColors.surface)
            .accessibilityIdentifier("AdaEditor.TileSourceEditor.Preview")
        } else {
            VStack(spacing: 12) {
                Text(model.sources.isEmpty ? "Tile Source" : "Image preview unavailable")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                Text("Choose a PNG sprite sheet, then set its tile size and spacing.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.muted)
                action("+ Add image", id: "EmptyAdd") { model.presentImagePicker() }
                    .disabled(!model.isEditable)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.editorColors.surface)
        }
    }

    private func sourceCard(at index: Int) -> some View {
        let selected = index == model.selectedSource
        return VStack(alignment: .leading, spacing: 8) {
            action(model.sourceName(at: index), id: "Source.\(index)") { model.selectSource(index) }
            if model.previews.indices.contains(index), let preview = model.previews[index] {
                let scale = min(model.zoom, min(208 / Float(preview.image.width), 180 / Float(preview.image.height)))
                let imageWidth = Float(preview.image.width) * scale
                let imageHeight = Float(preview.image.height) * scale
                ZStack {
                    preview.image.resizable().frame(width: imageWidth, height: imageHeight)
                    if selected {
                        grid(layout: preview.layout, scale: scale)
                            .frame(width: imageWidth, height: imageHeight)
                    }
                }
                .frame(width: imageWidth, height: imageHeight)
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    model.selectSource(index)
                    let x = value.location.x / scale - Float(preview.layout.margin.width)
                    let y = value.location.y / scale - Float(preview.layout.margin.height)
                    guard x >= 0, y >= 0 else { return }
                    let strideX = Float(preview.layout.tileSize.width + preview.layout.spacing.width)
                    let strideY = Float(preview.layout.tileSize.height + preview.layout.spacing.height)
                    guard x.truncatingRemainder(dividingBy: strideX) < Float(preview.layout.tileSize.width),
                          y.truncatingRemainder(dividingBy: strideY) < Float(preview.layout.tileSize.height) else { return }
                    model.selectTile([Int(x / strideX), Int(y / strideY)])
                })
            } else {
                Text("Preview unavailable")
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 228, height: 246, alignment: .topLeading)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surfaceElevated))
        .overlay {
            RoundedRectangleShape(cornerRadius: 6)
                .stroke(selected ? theme.editorColors.blue : theme.editorColors.border, lineWidth: selected ? 2 : 1)
        }
        .accessibilityIdentifier("AdaEditor.TileSourceEditor.Card.\(index)")
    }

    private func grid(layout: TileSourceImageDescriptor, scale: Float) -> some View {
        Canvas { context, _ in
            let grid = layout.gridSize(imageSize: [model.image?.width ?? 0, model.image?.height ?? 0])
            func outline(_ rect: Rect, color: Color, thickness: Float) {
                context.drawRect(Rect(x: rect.minX, y: rect.minY, width: rect.width, height: thickness), color: color)
                context.drawRect(Rect(x: rect.minX, y: rect.maxY - thickness, width: rect.width, height: thickness), color: color)
                context.drawRect(Rect(x: rect.minX, y: rect.minY, width: thickness, height: rect.height), color: color)
                context.drawRect(Rect(x: rect.maxX - thickness, y: rect.minY, width: thickness, height: rect.height), color: color)
            }
            if model.showGrid, grid.width * grid.height <= 65_536 {
                for y in 0..<grid.height {
                    for x in 0..<grid.width {
                        outline(tileRect([x, y], layout: layout, scale: scale), color: .white.opacity(0.35), thickness: 1)
                    }
                }
            }
            for tile in model.tiles {
                guard let xy = tile["xy"] as? [Int], xy.count == 2 else {
                    continue
                }
                outline(tileRect([xy[0], xy[1]], layout: layout, scale: scale), color: theme.editorColors.blue.opacity(0.8), thickness: 1)
            }
            if let selected = model.selectedTile {
                context.drawRect(tileRect(selected, layout: layout, scale: scale), color: theme.editorColors.blue.opacity(0.25))
                outline(tileRect(selected, layout: layout, scale: scale), color: .white, thickness: 2)
            }
        }
    }

    private func tileRect(_ point: PointInt, layout: TileSourceImageDescriptor, scale: Float) -> Rect {
        Rect(
            x: Float(layout.margin.width + point.x * (layout.tileSize.width + layout.spacing.width)) * scale,
            y: Float(layout.margin.height + point.y * (layout.tileSize.height + layout.spacing.height)) * scale,
            width: Float(layout.tileSize.width) * scale,
            height: Float(layout.tileSize.height) * scale
        )
    }

    var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                adaEditorInspectorTitle(theme: theme)
                heading("Tile Source")
                action("+ Add image", id: "Add") { model.presentImagePicker() }.disabled(!model.isEditable)
                if !model.sources.isEmpty {
                    Text("Selected: \(model.sourceName(at: model.selectedSource))")
                        .font(.system(size: 11))
                        .foregroundColor(theme.editorColors.muted)
                    action("Remove source", id: "RemoveSource") { model.removeSource() }.disabled(!model.isEditable)
                }
                Divider()
                heading("Tile Set")
                field("Tile width", text: binding(\.displayWidth))
                field("Tile height", text: binding(\.displayHeight))
                imageInspector
                action("Apply settings", id: "ApplySettings") { model.applySettings() }.disabled(!model.isEditable)
                if model.canEditSource {
                    Divider()
                    heading("Tiles • \(model.tiles.count)")
                    action("Create all tiles", id: "CreateAll") { model.createAllTiles() }
                    tileInspector
                }
            }
            .padding(12)
        }
        .background(theme.editorColors.surfaceElevated)
        .accessibilityIdentifier("AdaEditor.TileSourceEditor.Inspector")
    }

    @ViewBuilder private var imageInspector: some View {
        if model.layout != nil {
            Divider()
            heading("Image")
            Text(model.layout?.path ?? "")
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(3)
            if let image = model.image {
                Text("\(image.width) × \(image.height) px • \(model.gridSize.width) × \(model.gridSize.height) cells")
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.muted)
            }
            field("Name", text: binding(\.name))
            field("Cell width", text: binding(\.width))
            field("Cell height", text: binding(\.height))
            field("Margin X", text: binding(\.marginX))
            field("Margin Y", text: binding(\.marginY))
            field("Spacing X", text: binding(\.spacingX))
            field("Spacing Y", text: binding(\.spacingY))
        }
    }

    @ViewBuilder private var tileInspector: some View {
        if let tile = model.selectedTile {
            Text("Cell \(tile.x), \(tile.y)")
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
            action(model.hasTile(tile) ? "Remove tile" : "Create tile", id: "ToggleTile") { model.toggleTile() }
            if model.hasTile(tile) {
                heading("Animation")
                field("Frames", text: binding(\.frames))
                field("Duration (s)", text: binding(\.duration))
                action(model.verticalAnimation ? "Direction: Vertical" : "Direction: Horizontal", id: "Direction") {
                    model.verticalAnimation.toggle()
                }
                action("Apply animation", id: "ApplyAnimation") { model.applyAnimation() }
            }
        } else {
            Text("Select a cell in the image")
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
        }
    }

    private func binding(_ key: ReferenceWritableKeyPath<EditorTileSourceEditorModel, String>) -> Binding<String> {
        Binding(get: { model[keyPath: key] }, set: { model[keyPath: key] = $0 })
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .bold)).foregroundColor(theme.editorColors.text)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundColor(theme.editorColors.muted).frame(width: 96)
            TextField(title, text: text)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(theme.editorColors.surface)
                .accessibilityIdentifier("AdaEditor.TileSourceEditor.Field.\(title)")
        }
    }

    private func action(_ title: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.blue)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.blue.opacity(0.12)))
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.TileSourceEditor.\(id)")
    }
}
