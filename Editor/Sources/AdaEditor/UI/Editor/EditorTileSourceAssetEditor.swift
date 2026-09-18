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
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                toolbar
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(model.status)
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            inspector
                .frame(width: 280)
                .frame(maxHeight: .infinity)
        }
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
        if let image = model.image, let layout = model.layout {
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    image.resizable()
                        .frame(width: Float(image.width) * model.zoom, height: Float(image.height) * model.zoom)
                    grid(layout: layout)
                        .frame(width: Float(image.width) * model.zoom, height: Float(image.height) * model.zoom)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let x = value.location.x / model.zoom - Float(layout.margin.width)
                            let y = value.location.y / model.zoom - Float(layout.margin.height)
                            guard x >= 0, y >= 0 else {
                                return
                            }
                            let strideX = Float(layout.tileSize.width + layout.spacing.width)
                            let strideY = Float(layout.tileSize.height + layout.spacing.height)
                            guard
                                x.truncatingRemainder(dividingBy: strideX) < Float(layout.tileSize.width),
                                y.truncatingRemainder(dividingBy: strideY) < Float(layout.tileSize.height)
                            else {
                                return
                            }
                            model.selectTile([Int(x / strideX), Int(y / strideY)])
                        }
                )
                .padding(24)
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

    private func grid(layout: TileSourceImageDescriptor) -> some View {
        Canvas { context, _ in
            let grid = model.gridSize
            func outline(_ rect: Rect, color: Color, thickness: Float) {
                context.drawRect(Rect(x: rect.minX, y: rect.minY, width: rect.width, height: thickness), color: color)
                context.drawRect(Rect(x: rect.minX, y: rect.maxY - thickness, width: rect.width, height: thickness), color: color)
                context.drawRect(Rect(x: rect.minX, y: rect.minY, width: thickness, height: rect.height), color: color)
                context.drawRect(Rect(x: rect.maxX - thickness, y: rect.minY, width: thickness, height: rect.height), color: color)
            }
            if model.showGrid, grid.width * grid.height <= 65_536 {
                for y in 0..<grid.height {
                    for x in 0..<grid.width {
                        outline(tileRect([x, y], layout: layout), color: .white.opacity(0.35), thickness: 1)
                    }
                }
            }
            for tile in model.tiles {
                guard let xy = tile["xy"] as? [Int], xy.count == 2 else {
                    continue
                }
                outline(tileRect([xy[0], xy[1]], layout: layout), color: theme.editorColors.blue.opacity(0.8), thickness: 1)
            }
            if let selected = model.selectedTile {
                context.drawRect(tileRect(selected, layout: layout), color: theme.editorColors.blue.opacity(0.25))
                outline(tileRect(selected, layout: layout), color: .white, thickness: 2)
            }
        }
    }

    private func tileRect(_ point: PointInt, layout: TileSourceImageDescriptor) -> Rect {
        Rect(
            x: Float(layout.margin.width + point.x * (layout.tileSize.width + layout.spacing.width)) * model.zoom,
            y: Float(layout.margin.height + point.y * (layout.tileSize.height + layout.spacing.height)) * model.zoom,
            width: Float(layout.tileSize.width) * model.zoom,
            height: Float(layout.tileSize.height) * model.zoom
        )
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    heading("Sources")
                    Spacer()
                    action("+ Add", id: "Add") { model.presentImagePicker() }.disabled(!model.isEditable)
                }
                ForEach(Array(model.sources.indices), id: \.self) { index in
                    action("\(model.sourceName(at: index))\(index == model.selectedSource ? "  •" : "")", id: "Source.\(index)") {
                        model.selectSource(index)
                    }
                }
                if !model.sources.isEmpty {
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
