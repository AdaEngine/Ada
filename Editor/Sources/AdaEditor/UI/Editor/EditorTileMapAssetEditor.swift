@_spi(AdaEngine) import AdaEngine

struct EditorTileMapAssetEditor: View {
    let document: EditorAssetDocument
    @State private var model: EditorTileMapEditorModel
    @Environment(\.theme) private var theme

    init(document: EditorAssetDocument, model: EditorTileMapEditorModel? = nil, onSave: (() -> Void)? = nil) {
        self.document = document
        self._model = State(initialValue: model ?? EditorTileMapEditorModel(document: document, onSave: onSave))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                inspector
                    .frame(width: 236)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.editorColors.background)
        .accessibilityIdentifier("AdaEditor.TileMapEditor")
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(document.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(1)
                Spacer()
                toolbarButton("Reload", id: "Reload") { model.reload() }
            }
            Text("TILE MAP  ·  \(Int(model.displayTileSize.width)) × \(Int(model.displayTileSize.height))  ·  Y UP")
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(1)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(EditorTileMapEditorModel.Tool.allCases, id: \.self) { tool in
                        toolbarButton(tool.rawValue, selected: model.tool == tool, id: tool.rawValue) { model.tool = tool }
                    }
                    Text("\(Int(model.zoom * 100))%")
                        .font(.system(size: 11))
                        .foregroundColor(theme.editorColors.text)
                        .frame(width: 44)
                    toolbarButton("−", id: "ZoomOut") { model.setZoom(model.zoom / 1.25) }
                    toolbarButton("+", id: "ZoomIn") { model.setZoom(model.zoom * 1.25) }
                    toolbarButton("Fit map", id: "Fit") { model.fitMap(in: model.viewportSize) }
                    toolbarButton(model.showGrid ? "Grid on" : "Grid off", selected: model.showGrid, id: "Grid") {
                        model.showGrid.toggle()
                    }
                }
            }
        }
        .padding(12)
        .background(theme.editorColors.surfaceElevated)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                drawMap(in: context, size: size)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .mask(RectangleShape())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if model.tool == .pan {
                            model.pan(by: value.translation)
                        } else {
                            model.paint(at: canvasLocalPoint(value.location, in: geometry), in: geometry.size)
                        }
                    }
                    .onEnded { value in
                        if model.tool == .pan {
                            model.endPan()
                        } else {
                            model.paint(at: canvasLocalPoint(value.location, in: geometry), in: geometry.size)
                            model.endStroke()
                        }
                    }
            )
            .onPointerNavigation(
                scroll: { event in
                    model.handleScroll(event, at: canvasLocalPoint(event.mousePosition, in: geometry), in: geometry.size)
                },
                pinch: { event in
                    model.handlePinch(event, at: canvasLocalPoint(event.location, in: geometry), in: geometry.size)
                },
                secondaryDrag: { event in
                    switch event.phase {
                    case .began, .changed:
                        model.erase(at: canvasLocalPoint(event.mousePosition, in: geometry), in: geometry.size)
                    case .ended:
                        model.erase(at: canvasLocalPoint(event.mousePosition, in: geometry), in: geometry.size)
                        model.endStroke()
                    case .cancelled:
                        model.endStroke()
                    }
                }
            )
            .accessibilityIdentifier("AdaEditor.TileMapEditor.Canvas")
        }
        .background(theme.editorColors.surface)
    }

    private func drawMap(in context: UIGraphicsContext, size: Size) {
        guard size.width > 0, size.height > 0 else { return }
        model.updateViewportSize(size)
        _ = model.revision
        context.drawRect(Rect(origin: .zero, size: size), color: theme.editorColors.surface)
        let origin = model.canvasOrigin(in: size)
        let cellWidth = model.cellWidth
        let cellHeight = model.cellHeight
        let minX = Int(floor(-origin.x / cellWidth - 0.5))
        let maxX = Int(ceil((size.width - origin.x) / cellWidth + 0.5))
        let minY = Int(floor((origin.y - size.height) / cellHeight - 0.5))
        let maxY = Int(ceil(origin.y / cellHeight + 0.5))
        for y in minY...maxY {
            for x in minX...maxX {
                guard let color = model.color(atX: x, y: y) else { continue }
                let rect = model.tileRect(atX: x, y: y, in: size)
                if let index = model.tileIndex(atX: x, y: y), let texture = model.texture(at: index) {
                    context.drawRect(rect, texture: texture, color: .white)
                } else {
                    context.drawRect(rect, color: color)
                }
            }
        }
        guard model.showGrid else { return }
        for x in minX...maxX {
            let position = origin.x + (Float(x) - 0.5) * cellWidth
            let tint = theme.editorColors.border.opacity(x.isMultiple(of: 8) ? 0.8 : 0.5)
            context.drawRect(Rect(x: position, y: 0, width: 1, height: size.height), color: tint)
        }
        for y in minY...maxY {
            let position = origin.y - (Float(y) + 0.5) * cellHeight
            let tint = theme.editorColors.border.opacity(y.isMultiple(of: 8) ? 0.8 : 0.5)
            context.drawRect(Rect(x: 0, y: position, width: size.width, height: 1), color: tint)
        }
        context.drawRect(Rect(x: origin.x, y: 0, width: 1, height: size.height), color: theme.editorColors.blue.opacity(0.7))
        context.drawRect(Rect(x: 0, y: origin.y, width: size.width, height: 1), color: theme.editorColors.blue.opacity(0.7))
    }

    private func canvasLocalPoint(_ windowPoint: Point, in geometry: GeometryProxy) -> Point {
        let frame = geometry.frame(in: .global)
        return Point(x: windowPoint.x - frame.minX, y: windowPoint.y - frame.minY)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PALETTE")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.editorColors.muted)
            Text("Choose a tile, then paint on the canvas.")
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
            VStack(alignment: .leading, spacing: 7) {
                Text("TILE SOURCE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.editorColors.muted)
                HStack(spacing: 6) {
                    toolbarButton("Link…", id: "LinkTileSet") { model.presentTileSetPicker() }
                    if model.map.tileSetReference == nil {
                        toolbarButton("New", id: "NewTileSet") { model.createTileSet() }
                    } else {
                        toolbarButton("Refresh", id: "RefreshTileSet") { model.refreshTileSet() }
                    }
                }
                Text(model.tileSetStatus)
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(3)
                Text(model.map.tileSetReference == nil
                    ? "New creates a .tileset; Link chooses one already in Assets."
                    : "Open the .tileset in Assets → Add image → Create all tiles → Refresh here.")
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(4)
            }
            .padding(8)
            .background(RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.surface))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<model.paletteCount, id: \.self) { index in
                        paletteButton(index)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Text("New color")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.editorColors.text)
            HStack(spacing: 6) {
                TextField("RRGGBB", text: Binding(get: { model.newColorHex }, set: { model.newColorHex = $0 }))
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.text)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(7)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
                    .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border, lineWidth: 1) }
                toolbarButton("+ Color", id: "AddColor") { model.addColor() }
            }
            .frame(height: 34)
            Text("Left click paints · right click erases. Scroll to pan; pinch or ⌘/Ctrl + wheel to zoom.")
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(4)
        }
        .padding(12)
        .background(theme.editorColors.surfaceElevated)
    }

    private func paletteButton(_ index: Int) -> some View {
        let selected = model.selectedColor == index && model.tool == .paint
        return Button(action: { model.selectedColor = index; model.tool = .paint }) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangleShape(cornerRadius: 5)
                        .fill(model.paletteColor(at: index))
                    if let image = model.image(at: index) {
                        image.resizable()
                    }
                }
                .frame(width: 38, height: 38)
                Text(model.paletteLabel(at: index))
                    .font(.system(size: 12, weight: selected ? .bold : .regular))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(1)
                Spacer()
                Text(selected ? "Selected" : "")
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.blue)
            }
            .padding(7)
            .background(RoundedRectangleShape(cornerRadius: 7).fill(selected ? theme.editorColors.blue.opacity(0.16) : theme.editorColors.surface))
            .overlay { RoundedRectangleShape(cornerRadius: 7).stroke(selected ? theme.editorColors.blue : theme.editorColors.border, lineWidth: 1) }
        }
        .accessibilityIdentifier("AdaEditor.TileMapEditor.Color.\(index)")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(model.map.cells.count) cells")
                .foregroundColor(theme.editorColors.text)
            Text("Zoom \(Int(model.zoom * 100))%")
                .foregroundColor(theme.editorColors.muted)
            Spacer()
            Text(model.status)
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .padding(9)
        .background(theme.editorColors.surfaceElevated)
    }

    private func toolbarButton(_ title: String, selected: Bool = false, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: selected ? .bold : .regular))
            .foregroundColor(selected ? theme.editorColors.text : theme.editorColors.muted)
            .padding(7)
            .background(RoundedRectangleShape(cornerRadius: 6).fill(selected ? theme.editorColors.blue.opacity(0.24) : theme.editorColors.surface))
            .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(selected ? theme.editorColors.blue : theme.editorColors.border, lineWidth: 1) }
            .accessibilityIdentifier("AdaEditor.TileMapEditor.\(id)")
    }
}
