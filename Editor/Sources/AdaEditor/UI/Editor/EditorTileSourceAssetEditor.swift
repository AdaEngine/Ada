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
            action("−", id: "ZoomOut") { model.setZoom(model.zoom / 1.5) }
            Text("\(Int(model.zoom * 100))%")
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.muted)
            action("+", id: "ZoomIn") { model.setZoom(model.zoom * 1.5) }
            action("Fit", id: "Fit") { model.resetViewport() }
            action(model.showGrid ? "Hide grid" : "Show grid", id: "Grid") { model.showGrid.toggle() }
            action("Reload", id: "Reload") { model.reload() }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if !model.sources.isEmpty {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    sourceStrip
                    GeometryReader { canvas in
                        if model.previews.indices.contains(model.selectedSource),
                           let sourcePreview = model.previews[model.selectedSource] {
                            let imageWidth = Float(sourcePreview.image.width)
                            let imageHeight = Float(sourcePreview.image.height)
                            let fitScale = min(
                                max(1, Float(canvas.size.width) * 0.86) / imageWidth,
                                max(1, Float(canvas.size.height) * 0.86) / imageHeight
                            )
                            let scale = min(1, fitScale) * model.zoom
                            let displayWidth = imageWidth * scale
                            let displayHeight = imageHeight * scale

                            ZStack {
                                sourcePreview.image.resizable().frame(width: displayWidth, height: displayHeight)
                                grid(layout: sourcePreview.layout, scale: scale)
                                    .frame(width: displayWidth, height: displayHeight)
                            }
                            .frame(width: displayWidth, height: displayHeight)
                            .accessibilityIdentifier("AdaEditor.TileSourceEditor.Canvas")
                            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                                let local = canvasLocalPoint(value.location, in: canvas)
                                let origin = Point(
                                    (canvas.size.width - displayWidth) / 2 + model.panOffset.x,
                                    (canvas.size.height - displayHeight) / 2 + model.panOffset.y
                                )
                                selectTile(at: Point(local.x - origin.x, local.y - origin.y), preview: sourcePreview, scale: scale)
                            })
                            .offset(x: model.panOffset.x, y: model.panOffset.y)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .mask(RectangleShape())
                            .onPointerNavigation(
                                scroll: { event in
                                    model.handleScroll(event, at: canvasLocalPoint(event.mousePosition, in: canvas), in: canvas.size)
                                },
                                pinch: { event in
                                    model.handlePinch(event, at: canvasLocalPoint(event.location, in: canvas), in: canvas.size)
                                },
                                secondaryDrag: { model.handleSecondaryDrag($0) }
                            )
                        } else {
                            Text("Image preview unavailable")
                                .font(.system(size: 12))
                                .foregroundColor(theme.editorColors.muted)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
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

    private var sourceStrip: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.sources.indices, id: \.self) { index in
                        let selected = index == model.selectedSource
                        Button {
                            model.selectSource(index)
                        } label: {
                            Text(model.sourceName(at: index))
                                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                                .foregroundColor(selected ? theme.editorColors.text : theme.editorColors.muted)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(RoundedRectangleShape(cornerRadius: 5).fill(selected ? theme.editorColors.surfaceElevated : .clear))
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .accessibilityIdentifier("AdaEditor.TileSourceEditor.Source.\(index)")
                    }
                }
                .padding(.horizontal, 10)
            }
            theme.editorColors.border.opacity(0.65).frame(height: 1)
        }
        .frame(height: 40)
    }

    private func canvasLocalPoint(_ windowPoint: Point, in geometry: GeometryProxy) -> Point {
        let frame = geometry.frame(in: .global)
        return Point(windowPoint.x - frame.minX, windowPoint.y - frame.minY)
    }

    private func selectTile(at location: Point, preview: EditorTileSourcePreview, scale: Float) {
        let x = location.x / scale - Float(preview.layout.margin.width)
        let y = location.y / scale - Float(preview.layout.margin.height)
        guard x >= 0, y >= 0 else {
            return
        }
        let strideX = Float(preview.layout.tileSize.width + preview.layout.spacing.width)
        let strideY = Float(preview.layout.tileSize.height + preview.layout.spacing.height)
        guard
            x.truncatingRemainder(dividingBy: strideX) < Float(preview.layout.tileSize.width),
            y.truncatingRemainder(dividingBy: strideY) < Float(preview.layout.tileSize.height)
        else {
            return
        }
        model.selectTile([Int(x / strideX), Int(y / strideY)])
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
