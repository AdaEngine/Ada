@_spi(AdaEngine) import AdaEngine
import Foundation

/// A drag commits one field edit, so scene Undo restores the entire gesture.
struct EditorColorCurvesField: View {
    let text: Binding<String>
    @State private var channel = "Master RGB"
    @State private var selectedPoint: Int?
    @State private var draft: ColorCurve3D?
    @Environment(\.theme) private var theme

    private var curves: ColorCurves3D {
        (try? JSONDecoder().decode(ColorCurves3D.self, from: Data(text.wrappedValue.utf8))) ?? ColorCurves3D()
    }

    private var path: WritableKeyPath<ColorCurves3D, ColorCurve3D> {
        switch channel {
        case "Red": \.red
        case "Green": \.green
        case "Blue": \.blue
        default: \.master
        }
    }

    private var curve: ColorCurve3D { draft ?? curves[keyPath: path].sanitized }
    private var tint: Color {
        switch channel {
        case "Red": .red
        case "Green": .green
        case "Blue": theme.editorColors.blue
        default: theme.editorColors.text
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorEnumField(cases: ["Master RGB", "Red", "Green", "Blue"], selection: $channel, accessibilityID: "AdaEditor.ColorCorrection.Channel")
            GeometryReader { geometry in
                Canvas { context, size in
                    context.drawRect(Rect(origin: .zero, size: size), color: theme.editorColors.surface)
                    for step in 1..<4 {
                        let fraction = Float(step) / 4
                        context.drawLine(start: [fraction * size.width, 0], end: [fraction * size.width, -size.height], lineWidth: 1, color: theme.editorColors.border)
                        context.drawLine(start: [0, -fraction * size.height], end: [size.width, -fraction * size.height], lineWidth: 1, color: theme.editorColors.border)
                    }
                    let current = curve
                    let samples = current.sampledValues(count: 129)
                    for step in 1...128 {
                        let x0 = Float(step - 1) / 128, x1 = Float(step) / 128
                        context.drawLine(
                            start: [x0 * size.width, -(1 - samples[step - 1]) * size.height],
                            end: [x1 * size.width, -(1 - samples[step]) * size.height], lineWidth: 2, color: tint
                        )
                    }
                    for (index, point) in current.points.enumerated() {
                        context.drawRect(
                            Rect(x: point.input * size.width - 4, y: (1 - point.output) * size.height - 4, width: 8, height: 8),
                            color: index == selectedPoint ? theme.editorColors.blue : tint
                        )
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                    let frame = geometry.frame(in: .global)
                    let origin = Point(frame.minX, frame.minY)
                    let start = value.startLocation - origin
                    if draft == nil {
                        selectedPoint = curve.points.indices.min {
                            distance(curve.points[$0], to: start, size: geometry.size) < distance(curve.points[$1], to: start, size: geometry.size)
                        }
                        draft = curve
                    }
                    guard let selectedPoint else { return }
                    let location = value.location - origin
                    draft = Self.moving(curve, point: selectedPoint, input: location.x / geometry.size.width, output: 1 - location.y / geometry.size.height)
                }.onEnded { _ in
                    if let draft { save(draft) }
                    draft = nil
                })
            }
            .frame(height: 150)
            .accessibilityIdentifier("AdaEditor.ColorCorrection.Curve")
            HStack(spacing: 6) {
                Button(L10n.text("+ Point")) { addPoint() }.disabled(curve.points.count >= 32)
                Button(L10n.text("− Point")) { removePoint() }.disabled(!canRemove)
                Spacer()
                Button(L10n.text("Reset Curve")) { save(ColorCurve3D()); selectedPoint = nil }
            }
            .font(.system(size: 10))
            .buttonStyle(DefaultButtonStyle())
            Text(L10n.text("Drag points to change colors. Left: shadows. Right: highlights."))
                .font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
                .lineLimit(3)
        }
        .onChange(of: channel) { _, _ in draft = nil; selectedPoint = nil }
    }

    private var canRemove: Bool {
        if let selectedPoint { return selectedPoint > 0 && selectedPoint < curve.points.count - 1 }
        return false
    }

    private func save(_ curve: ColorCurve3D) {
        var updated = curves
        updated[keyPath: path] = curve.sanitized
        guard let data = try? JSONEncoder().encode(updated), let json = String(data: data, encoding: .utf8) else { return }
        text.wrappedValue = json
    }

    private func addPoint() {
        var current = curve
        guard current.points.count < 32 else { return }
        let gap = (0..<(current.points.count - 1)).max {
            current.points[$0 + 1].input - current.points[$0].input < current.points[$1 + 1].input - current.points[$1].input
        } ?? 0
        let input = (current.points[gap].input + current.points[gap + 1].input) / 2
        let point = ColorCurve3D.Point(input, current.evaluate(at: input))
        current.points.insert(point, at: gap + 1)
        selectedPoint = gap + 1
        save(current)
    }

    private func removePoint() {
        guard canRemove, let selectedPoint else { return }
        var current = curve
        current.points.remove(at: selectedPoint)
        save(current)
        self.selectedPoint = nil
    }

    static func moving(_ curve: ColorCurve3D, point: Int, input: Float, output: Float) -> ColorCurve3D {
        var result = curve.sanitized
        guard result.points.indices.contains(point), input.isFinite, output.isFinite else { return result }
        let low = point == 0 ? 0 : result.points[point - 1].input + 0.0001
        let high = point == result.points.count - 1 ? 1 : result.points[point + 1].input - 0.0001
        result.points[point].input = point == 0 ? 0 : (point == result.points.count - 1 ? 1 : min(max(input, low), high))
        result.points[point].output = min(max(output, 0), 1)
        return result
    }

    private func distance(_ point: ColorCurve3D.Point, to location: Point, size: Size) -> Float {
        let delta = Point(point.input * size.width, (1 - point.output) * size.height) - location
        return delta.x * delta.x + delta.y * delta.y
    }
}
