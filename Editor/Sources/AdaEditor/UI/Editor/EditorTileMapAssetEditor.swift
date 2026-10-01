@_spi(AdaEngine) import AdaEngine

struct EditorTileMapAssetEditor: View {
    let document: EditorAssetDocument
    @State private var model: EditorTileMapEditorModel
    @State private var hoveredTool: String?
    @Environment(\.theme) private var theme

    init(document: EditorAssetDocument, model: EditorTileMapEditorModel? = nil, onSave: (() -> Void)? = nil) {
        self.document = document
        self._model = State._makeStorage {
            model ?? EditorTileMapEditorModel(document: document, onSave: onSave)
        }
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(EditorTileMapEditorModel.Tool.allCases, id: \.self) { tool in
                    toolbarButton(tool.rawValue, selected: model.tool == tool, id: tool.rawValue) { model.tool = tool }
                }
                RectangleShape().fill(theme.editorColors.border).frame(width: 1, height: 20).padding(.horizontal, 4)
                toolbarButton("−", id: "ZoomOut") { model.setZoom(model.zoom / 1.25) }
                Text("\(Int(model.zoom * 100))%")
                    .font(.system(size: 11)).foregroundColor(theme.editorColors.text).frame(width: 44)
                toolbarButton("+", id: "ZoomIn") { model.setZoom(model.zoom * 1.25) }
                toolbarButton("Fit map", id: "Fit") { model.fitMap(in: model.viewportSize) }
                toolbarButton("Grid", selected: model.showGrid, id: "Grid") { model.showGrid.toggle() }
                toolbarButton("Reload", id: "Reload") { model.reload() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
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
                                model.paint(at: canvasLocalPoint(value.location, in: geometry), in: geometry.frame(in: .global).size)
                            }
                        }
                        .onEnded { value in
                            if model.tool == .pan {
                                model.endPan()
                            } else {
                                model.paint(at: canvasLocalPoint(value.location, in: geometry), in: geometry.frame(in: .global).size)
                                model.endStroke()
                            }
                        }
                )
                .onPointerNavigation(
                    scroll: { event in
                        model.handleScroll(event, at: canvasLocalPoint(event.mousePosition, in: geometry), in: geometry.frame(in: .global).size)
                    },
                    pinch: { event in
                        model.handlePinch(event, at: canvasLocalPoint(event.location, in: geometry), in: geometry.frame(in: .global).size)
                    },
                    secondaryDrag: { event in
                        switch event.phase {
                        case .began, .changed:
                            model.erase(at: canvasLocalPoint(event.mousePosition, in: geometry), in: geometry.frame(in: .global).size)
                        case .ended:
                            model.erase(at: canvasLocalPoint(event.mousePosition, in: geometry), in: geometry.frame(in: .global).size)
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
        // Gesture callbacks survive relayout; resolve origin AND size from the live node.
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
            Text(hoveredTool ?? model.status)
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(theme.editorColors.surfaceElevated)
    }

    private func toolbarButton(_ title: String, selected: Bool = false, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(toolbarSymbol(id))
                .font(AdaEditorMaterialSymbolFont.font(size: 18))
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 6)
                .frame(minWidth: 30, minHeight: 30)
        }
        .buttonStyle(EditorTileMapButtonStyle(theme: theme))
        .background(RoundedRectangleShape(cornerRadius: 6).fill(selected ? theme.editorColors.blue.opacity(0.22) : theme.editorColors.surface))
        .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(selected ? theme.editorColors.blue : theme.editorColors.border, lineWidth: 1) }
        .onHover { hoveredTool = $0 ? title : nil }
        .accessibilityIdentifier("AdaEditor.TileMapEditor.\(id)")
    }
    private func toolbarSymbol(_ id: String) -> String {
        switch id {
        case "Paint": "\u{E3AE}"
        case "Erase": "\u{E1B8}"
        case "Pan": "\u{E9E9}"
        case "ZoomOut": "\u{E900}"
        case "ZoomIn": "\u{E8FF}"
        case "Fit": "\u{E5D0}"
        case "Grid": "\u{E3EC}"
        default: "\u{E5D5}"
        }
    }

}
