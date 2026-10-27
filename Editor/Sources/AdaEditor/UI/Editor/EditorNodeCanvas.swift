@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI

/// Drawing and geometry have no dependency on a shader/animation document schema.
struct EditorNodeCanvas: View {
    let items: [EditorNodeCanvasItem]
    let wires: [EditorNodeCanvasWire]
    let selection: Set<String>
    let state: EditorNodeCanvasState
    var revision: UInt64 = 0
    var interaction: EditorNodeCanvasInteraction?
    var decorations: [EditorNodeCanvasDecoration] = []
    var onKeyEvent: (KeyEvent) -> Void = { _ in }
    var viewportSizeChanged: (Size) -> Void = { _ in }
    var selectedWire: EditorNodeCanvasWire?
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let ordered = items.filter { !selection.contains($0.id) } + items.filter { selection.contains($0.id) }
            let geometry = EditorNodeCanvasGeometry(nodes: ordered, pan: state.pan, zoom: state.zoom)
            ZStack(anchor: .topLeading) {
                RectangleShape().fill(theme.editorColors.background)
                ForEach(decorations) { item in
                    let point = geometry.screen([item.bounds.minX, item.bounds.minY])
                    VStack(alignment: .leading) {
                        Text(verbatim: item.title).font(.system(size: 12, weight: .semibold)).lineLimit(item.isNote ? 5 : 1).foregroundColor(theme.editorColors.text).padding(8)
                        Spacer(minLength: 0)
                    }.frame(width: item.bounds.width, height: item.bounds.height, alignment: .topLeading).background(
                        RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.blue.opacity(item.isNote ? 0.16 : 0.06))
                    ).overlay { RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.blue.opacity(0.35), lineWidth: 1) }.scaleEffect(
                        [state.zoom, state.zoom],
                        anchor: .topLeading
                    ).offset(x: point.x, y: point.y).allowsHitTesting(false)
                }
                Canvas(drawingRevision: { revision &+ state.revision &+ (interaction?.revision ?? 0) }) { context, size in
                    drawGrid(context: &context, size: size)
                    for wire in wires {
                        if let start = geometry.port(wire.source), let end = geometry.port(wire.target) {
                            if max(start.y, end.y) >= -20, min(start.y, end.y) <= size.height + 20 {
                                Self.drawWire(
                                    context: &context, start: start, end: end,
                                    color: wire == selectedWire ? theme.editorColors.blue : Self.portColor(wire.type),
                                    lineWidth: wire == selectedWire ? 4 : 2
                                )
                            }
                        }
                    }
                    if let interaction, let anchor = interaction.anchor, let point = geometry.port(anchor) {
                        Self.drawWire(
                            context: &context,
                            start: anchor.isOutput ? point : interaction.cursor,
                            end: anchor.isOutput ? interaction.cursor : point,
                            color: theme.editorColors.blue
                        )
                    }
                    if let rect = interaction?.marquee { context.drawRect(rect, color: theme.editorColors.blue.opacity(0.18)) }
                }
                ForEach(ordered) { item in
                    let bounds = geometry.bounds(item)
                    if bounds.maxX > -80, bounds.minX < proxy.size.width + 80, bounds.maxY > -80, bounds.minY < proxy.size.height + 80 {
                        card(item).scaleEffect([state.zoom, state.zoom], anchor: .topLeading).offset(x: bounds.minX, y: bounds.minY).allowsHitTesting(false)
                    }
                }
                EditorNodeCanvasInput(
                    geometry: geometry, wires: wires, selection: selection,
                    state: state, interaction: interaction
                )
            }.frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading).mask(RectangleShape()).accessibilityIdentifier("AdaEditor.NodeCanvas").onFocusedKeyEvent(onKeyEvent)
                .onAppear { viewportSizeChanged(proxy.size) }
                .onChange(of: proxy.size) { _, size in viewportSizeChanged(size) }
        }
    }

    private func card(_ item: EditorNodeCanvasItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).foregroundColor(theme.editorColors.text).padding(.horizontal, 10).frame(
                width: EditorNodeCanvasGeometry.nodeWidth,
                height: 34,
                alignment: .leading
            ).background(theme.editorColors.blue.opacity(0.13))
            ForEach(0..<max(1, max(item.inputs.count, item.outputs.count)), id: \.self) { row in
                HStack(spacing: 5) {
                    if item.inputs.indices.contains(row) { port(item.inputs[row], output: false) }
                    Spacer(minLength: 4)
                    if item.outputs.indices.contains(row) { port(item.outputs[row], output: true) }
                }.padding(.horizontal, 8).frame(height: 24)
            }
            if let subtitle = item.subtitle {
                Text(verbatim: subtitle).font(.system(size: 10)).foregroundColor(theme.editorColors.muted).padding(.horizontal, 10).frame(height: 18).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.frame(width: EditorNodeCanvasGeometry.nodeWidth, height: item.height, alignment: .topLeading).background(
            RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.surfaceElevated)
        ).overlay {
            RoundedRectangleShape(cornerRadius: 7).stroke(
                item.hasError ? .red : selection.contains(item.id) ? theme.editorColors.blue : theme.editorColors.border,
                lineWidth: selection.contains(item.id) ? 2 : 1
            )
        }.accessibilityIdentifier("AdaEditor.NodeCanvas.Node.\(item.id)")
    }

    private func port(_ item: EditorNodeCanvasPort, output: Bool) -> some View {
        HStack(spacing: 5) {
            if !output { CircleShape().fill(Self.portColor(item.type)).frame(width: 10, height: 10) }
            Text(verbatim: item.title).font(.system(size: 10)).foregroundColor(theme.editorColors.text).lineLimit(1)
            if output { CircleShape().fill(Self.portColor(item.type)).frame(width: 10, height: 10) }
        }
    }

    private func drawGrid(context: inout UIGraphicsContext, size: Size) {
        let step = 24 * state.zoom
        guard size.width.isFinite, size.height.isFinite, step > 0 else {
            return
        }
        var x = state.pan.x.truncatingRemainder(dividingBy: step)
        while x < size.width {
            context.drawLine(start: [x, 0], end: [x, -size.height], lineWidth: 1, color: theme.editorColors.border.opacity(0.25))
            x += step
        }
        var y = state.pan.y.truncatingRemainder(dividingBy: step)
        while y < size.height {
            context.drawLine(start: [0, -y], end: [size.width, -y], lineWidth: 1, color: theme.editorColors.border.opacity(0.25))
            y += step
        }
    }

    static func drawWire(context: inout UIGraphicsContext, start: Vector2, end: Vector2, color: Color, lineWidth: Float = 2) {
        var previous = start
        for index in 1...24 {
            let point = EditorNodeCanvasGeometry.wirePoint(from: start, to: end, t: Float(index) / 24)
            // Layout and picking use downward Y; primitive line commands use the renderer's upward Y.
            context.drawLine(start: [previous.x, -previous.y], end: [point.x, -point.y], lineWidth: lineWidth, color: color)
            previous = point
        }
    }

    static func portColor(_ type: String) -> Color {
        switch type {
        case "texture2D": Color(red: 0.3, green: 0.65, blue: 1)
        case "color": Color(red: 1, green: 0.65, blue: 0.3)
        case "vector2", "vector3", "vector4": Color(red: 0.65, green: 0.5, blue: 1)
        case "bool": Color(red: 1, green: 0.4, blue: 0.5)
        default: Color(red: 0.45, green: 0.85, blue: 0.65)
        }
    }
}
