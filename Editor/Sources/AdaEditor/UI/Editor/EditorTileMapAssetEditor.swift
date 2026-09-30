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
                EditorTileMapSidebar(model: model)
                    .frame(width: 280)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(document.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(1)
                Text("\(Int(model.displayTileSize.width)) × \(Int(model.displayTileSize.height)) px")
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                Spacer()
                toolbarButton("Reload", id: "Reload") { model.reload() }
            }
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    ForEach(EditorTileMapEditorModel.Tool.allCases, id: \.self) { tool in
                        toolbarButton(tool.rawValue, selected: model.tool == tool, id: tool.rawValue) { model.tool = tool }
                    }
                    RectangleShape().fill(theme.editorColors.border).frame(width: 1, height: 20).padding(.horizontal, 6)
                    toolbarButton("−", id: "ZoomOut") { model.setZoom(model.zoom / 1.25) }
                    Text("\(Int(model.zoom * 100))%")
                        .font(.system(size: 12))
                        .foregroundColor(theme.editorColors.text)
                        .frame(width: 46)
                    toolbarButton("+", id: "ZoomIn") { model.setZoom(model.zoom * 1.25) }
                    toolbarButton("Fit map", id: "Fit") { model.fitMap(in: model.viewportSize) }
                    toolbarButton("Grid", selected: model.showGrid, id: "Grid") { model.showGrid.toggle() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.editorColors.surfaceElevated)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            EditorTileMapCanvas(model: model)
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

    private func canvasLocalPoint(_ windowPoint: Point, in geometry: GeometryProxy) -> Point {
        let frame = geometry.frame(in: .global)
        return Point(x: windowPoint.x - frame.minX, y: windowPoint.y - frame.minY)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(model.map.cellCount) cells · \(model.layers.count) layers")
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
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .bold : .regular))
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 10)
                .frame(minWidth: 30, minHeight: 30)
        }
        .buttonStyle(EditorTileMapButtonStyle(theme: theme))
        .background(RoundedRectangleShape(cornerRadius: 6).fill(selected ? theme.editorColors.blue.opacity(0.22) : theme.editorColors.surface))
        .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(selected ? theme.editorColors.blue : theme.editorColors.border, lineWidth: 1) }
        .accessibilityIdentifier("AdaEditor.TileMapEditor.\(id)")
    }
}
