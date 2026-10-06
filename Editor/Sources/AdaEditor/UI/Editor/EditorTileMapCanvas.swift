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
            let origin = model.canvasOrigin(in: size)
            model.visitVisibleTiles(in: size) { x, y, index in
                let rect = model.tileRect(atX: x, y: y, in: size)
                if let texture = model.texture(at: index) {
                    context.drawRect(rect, texture: texture, color: .white)
                } else {
                    context.drawRect(rect, color: model.paletteColor(at: index))
                }
            }
            if let cell = model.selectedCell {
                let rect = model.tileRect(atX: cell.x, y: cell.y, in: size)
                context.drawLine(start: [rect.minX, rect.minY], end: [rect.maxX, rect.minY], lineWidth: 2, color: .white)
                context.drawLine(start: [rect.maxX, rect.minY], end: [rect.maxX, rect.maxY], lineWidth: 2, color: .white)
                context.drawLine(start: [rect.maxX, rect.maxY], end: [rect.minX, rect.maxY], lineWidth: 2, color: .white)
                context.drawLine(start: [rect.minX, rect.maxY], end: [rect.minX, rect.minY], lineWidth: 2, color: .white)
            }
            if showGrid {
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
            }
            context.drawRect(Rect(x: origin.x - width / 2, y: 0, width: 1, height: size.height), color: Color(red: 0.24, green: 0.60, blue: 0.31).opacity(0.7))
            context.drawRect(Rect(x: 0, y: origin.y + height / 2, width: size.width, height: 1), color: Color(red: 0.78, green: 0.24, blue: 0.28).opacity(0.7))
            drawRulers(in: context, size: size, origin: origin, width: width, height: height)

        }

        private func drawRulers(in context: UIGraphicsContext, size: Size, origin: Point, width: Float, height: Float) {
            context.drawRect(Rect(x: 0, y: 0, width: size.width, height: 20), color: theme.editorColors.surface)
            context.drawRect(Rect(x: 0, y: 0, width: 40, height: size.height), color: theme.editorColors.surface)
            let stepX = max(1, Int(ceil(60 / width)))
            let stepY = max(1, Int(ceil(32 / height)))
            let minX = Int(floor(-origin.x / width))
            let maxX = Int(ceil((size.width - origin.x) / width))
            let minY = Int(floor((origin.y - size.height) / height))
            let maxY = Int(ceil(origin.y / height))
            for x in stride(from: minX - minX % stepX, through: maxX, by: stepX) {
                let position = origin.x + (Float(x) - 0.5) * width
                guard position > 64, position < size.width - 40 else { continue }
                drawLabel(String(x), at: Rect(x: position - 18, y: 2, width: 36, height: 16), in: context)
                context.drawRect(Rect(x: position, y: 16, width: 1, height: 4), color: theme.editorColors.muted)
            }
            for y in stride(from: minY - minY % stepY, through: maxY, by: stepY) {
                let position = origin.y - (Float(y) - 0.5) * height
                guard position > 36, position < size.height - 24 else { continue }
                drawLabel(String(y), at: Rect(x: 2, y: position - 8, width: 34, height: 16), in: context)
                context.drawRect(Rect(x: 36, y: position, width: 4, height: 1), color: theme.editorColors.muted)
            }
            drawLabel("X", at: Rect(x: size.width - 18, y: 2, width: 16, height: 16), in: context,
                      color: Color(red: 0.78, green: 0.24, blue: 0.28))
            drawLabel("Y", at: Rect(x: 2, y: size.height - 20, width: 16, height: 16), in: context,
                      color: Color(red: 0.24, green: 0.60, blue: 0.31))
        }

        private func drawLabel(_ text: String, at rect: Rect, in context: UIGraphicsContext, color: Color? = nil) {
            var attributes = TextAttributeContainer()
            attributes.font = .system(size: 9)
            attributes.foregroundColor = color ?? theme.editorColors.muted
            var container = TextContainer(text: AttributedText(text, attributes: attributes))
            container.numberOfLines = 1
            let layout = TextLayoutManager()
            layout.setTextContainer(container)
            layout.fitToSize(rect.size)

            var minX = Float.infinity
            var maxX = -Float.infinity
            var minY = Float.infinity
            var maxY = -Float.infinity
            for line in layout.textLines {
                for run in line {
                    for glyph in run {
                        minX = min(minX, glyph.position.x)
                        maxX = max(maxX, glyph.position.z)
                        minY = min(minY, glyph.position.y)
                        maxY = max(maxY, glyph.position.w)
                    }
                }
            }
            guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite else {
                return
            }

            // Glyph positions are already in points; the label bounds must not scale them.
            var labelContext = context
            labelContext.translateBy(
                x: rect.midX - (minX + maxX) / 2,
                y: -rect.midY - (minY + maxY) / 2
            )
            for line in layout.textLines {
                labelContext.draw(line)
            }
        }
    }
}
