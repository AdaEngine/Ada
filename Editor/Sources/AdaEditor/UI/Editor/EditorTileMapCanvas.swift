@_spi(AdaEngine) import AdaEngine

/// The body observes render inputs so a cached display list is invalidated by edits,
/// while drawing itself stays independent of the surrounding inspector and toolbar.
struct EditorTileMapCanvas: View {
    let model: EditorTileMapEditorModel
    @Environment(\.theme) private var theme

    var body: some View {
        let renderer = Renderer(
            model: model, theme: theme, revision: model.revision,
            zoom: model.zoom, offset: model.panOffset, showGrid: model.showGrid
        )
        return Canvas { context, size in
            renderer.draw(in: context, size: size)
        }
        .drawingGroup()
    }

    @MainActor
    private struct Renderer {
        let model: EditorTileMapEditorModel
        let theme: Theme
        let revision: Int
        let zoom: Float
        let offset: Point
        let showGrid: Bool

        func draw(in context: UIGraphicsContext, size: Size) {
            guard size.width > 0, size.height > 0 else { return }
            model.updateViewportSize(size)
            context.drawRect(Rect(origin: .zero, size: size), color: theme.editorColors.background)
            let width = model.displayTileSize.width * zoom
            let height = model.displayTileSize.height * zoom
            let origin = Point(x: size.width / 2 + offset.x, y: size.height / 2 + offset.y)
            model.visitVisibleTiles(in: size) { x, y, index in
                let rect = Rect(
                    x: origin.x + (Float(x) - 0.5) * width,
                    y: origin.y - (Float(y) + 0.5) * height,
                    width: width, height: height
                )
                if let texture = model.texture(at: index) {
                    context.drawRect(rect, texture: texture, color: .white)
                } else {
                    context.drawRect(rect, color: model.paletteColor(at: index))
                }
            }
            guard showGrid else { return }
            // Avoid a dense, high-contrast mesh when zooming out or using tiny tiles.
            let stepX = max(1, Int(ceil(12 / width)))
            let stepY = max(1, Int(ceil(12 / height)))
            let minX = Int(floor(-origin.x / width - 0.5))
            let maxX = Int(ceil((size.width - origin.x) / width + 0.5))
            let minY = Int(floor((origin.y - size.height) / height - 0.5))
            let maxY = Int(ceil(origin.y / height + 0.5))
            for x in stride(from: minX - minX % stepX, through: maxX, by: stepX) {
                let position = origin.x + (Float(x) - 0.5) * width
                let tint = theme.editorColors.border.opacity(x.isMultiple(of: 8) ? 0.5 : 0.22)
                context.drawRect(Rect(x: position, y: 0, width: 1, height: size.height), color: tint)
            }
            for y in stride(from: minY - minY % stepY, through: maxY, by: stepY) {
                let position = origin.y - (Float(y) + 0.5) * height
                let tint = theme.editorColors.border.opacity(y.isMultiple(of: 8) ? 0.5 : 0.22)
                context.drawRect(Rect(x: 0, y: position, width: size.width, height: 1), color: tint)
            }
            context.drawRect(Rect(x: origin.x, y: 0, width: 1, height: size.height), color: theme.editorColors.blue.opacity(0.35))
            context.drawRect(Rect(x: 0, y: origin.y, width: size.width, height: 1), color: theme.editorColors.blue.opacity(0.35))
        }
    }
}
