@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

/// Curves use production pose sampling; advanced tangent-handle modes remain the next milestone.
struct EditorAnimationCurves: View {
    let model: EditorAnimationTimelineModel
    @State private var curves: [[Vector2]] = []
    @State private var component = 0
    @State private var task: Task<Void, Never>?
    @State private var error = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(model.selectedTrack.map { L10n.tr($0.channel.rawValue) } ?? L10n.tr("Select a track"))
                    .font(.system(size: 11, weight: .semibold))
                ForEach(0..<min(4, curves.count), id: \.self) { index in
                    Button { component = index } label: {
                        Text(["X", "Y", "Z", "W"][index]).font(.system(size: 11)).padding(4)
                            .foregroundColor(index == component ? theme.editorColors.blue : theme.editorColors.text)
                    }.buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, selected: index == component))
                }
                if curves.count > 4 {
                    EditorEnumField(cases: curves.indices.map(String.init), selection: Binding(get: { String(component) }, set: { component = Int($0) ?? 0 }),
                        accessibilityID: "AdaEditor.AnimationCurves.Component", localizesValues: false).frame(width: 75)
                }
                Spacer(minLength: 0)
            }.padding(4).frame(height: 30)
            GeometryReader { geometry in
                let points = curves.indices.contains(component) ? curves[component] : []
                let lower = points.map(\.y).min() ?? 0
                let upper = points.map(\.y).max() ?? 1
                let spread = max(0.1, upper - lower)
                let minimum = lower - spread * 0.15
                let maximum = upper + spread * 0.15
                ZStack(anchor: .topLeading) {
                    RectangleShape().fill(theme.editorColors.background)
                    Canvas { context, size in
                        for tick in 0...8 {
                            let x = 42 + Float(tick) * max(1, size.width - 56) / 8
                            context.drawRect(Rect(x: x, y: 0, width: 1, height: size.height), color: theme.editorColors.border.opacity(0.3))
                        }
                        for tick in 0...4 {
                            context.drawRect(Rect(x: 42, y: Float(tick) * size.height / 4, width: max(0, size.width - 42), height: 1), color: theme.editorColors.border.opacity(0.3))
                        }
                        var previous: Point?
                        for point in points {
                            let current = project(point, size: size, minimum: minimum, maximum: maximum)
                            if let previous { context.drawLine(start: [previous.x, -previous.y], end: [current.x, -current.y], lineWidth: 2, color: curveColor) }
                            previous = current
                        }
                        for key in model.selectedTrack?.keys ?? [] where key.value.indices.contains(component) {
                            let point = project([Float(key.time), key.value[component]], size: size, minimum: minimum, maximum: maximum)
                            context.drawRect(Rect(x: point.x - 4, y: point.y - 4, width: 8, height: 8),
                                color: model.selectedKeys.contains(.init(track: model.selectedTrack?.id ?? "", key: key.id)) ? .yellow : curveColor)
                        }
                    }
                    Text(String(format: "%.3g", maximum)).font(.system(size: 10)).foregroundColor(theme.editorColors.muted).padding(3)
                    EditorAnimationCurveInput { point in
                        guard let track = model.selectedTrack else { return }
                        if let key = track.keys.first(where: { key in
                            guard key.value.indices.contains(component) else { return false }
                            return (project([Float(key.time), key.value[component]], size: geometry.size, minimum: minimum, maximum: maximum) - point).squaredLength < 81
                        }) {
                            model.selectKey(.init(track: track.id, key: key.id))
                            model.seek(key.time)
                        } else { model.seek(Double(max(0, point.x - 42) / max(1, geometry.size.width - 56)) * model.duration) }
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                    TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                        RectangleShape().fill(theme.editorColors.blue).frame(width: 1, height: geometry.size.height)
                            .offset(x: 42 + Float(model.time / max(0.01, model.duration)) * max(1, geometry.size.width - 56)).allowsHitTesting(false)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height).mask(RectangleShape())
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundColor(.red) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("AdaEditor.AnimationCurves.Editor")
            .onAppear { rebuild() }
            .onChange(of: model.workspace?.library?.revision) { _, _ in rebuild() }
            .onChange(of: model.clip?.id) { _, _ in rebuild() }
            .onChange(of: model.selectedTrack?.id) { _, _ in rebuild() }
            .onDisappear { task?.cancel() }
    }

    private var curveColor: Color { component == 0 ? Color(1, 0.4, 0.4, 1) : component == 1 ? Color(0.3, 0.9, 0.5, 1) : theme.editorColors.blue }

    private func project(_ point: Vector2, size: Size, minimum: Float, maximum: Float) -> Point {
        Point(42 + point.x / Float(max(0.01, model.duration)) * max(1, size.width - 56),
              size.height - (point.y - minimum) / max(0.01, maximum - minimum) * size.height)
    }

    private func rebuild() {
        task?.cancel()
        guard let library = model.library, let clip = model.clip, let track = model.selectedTrack else { curves = []; return }
        task = Task { @MainActor in
            do {
                let result = try await Self.sample(library: library, clipID: clip.id, track: track, duration: clip.duration)
                try Task.checkCancellation()
                curves = result
                component = min(component, max(0, result.count - 1))
                error = ""
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
        }
    }

    @concurrent private static func sample(library: AnimationLibrary, clipID: String, track: AnimationLibraryTrack, duration: Double) async throws -> [[Vector2]] {
        guard let node = library.binding.nodes.firstIndex(where: { $0.id == track.nodeID }) else { return [] }
        var player = try library.sample(clipID: clipID, at: 0)
        let width = track.channel == .weights ? library.binding.nodes[node].morphRestWeights?.count ?? 0 : track.channel == .rotation ? 4 : 3
        var result = Array(repeating: [Vector2](), count: width)
        for index in 0...128 {
            if index % 8 == 0 { try Task.checkCancellation() }
            let time = duration * Double(index) / 128
            player.seek(to: time)
            let pose = player.poses[node]
            let values: [Float]
            switch track.channel {
            case .translation: values = [pose.translation.x, pose.translation.y, pose.translation.z]
            case .rotation: values = [pose.rotation.x, pose.rotation.y, pose.rotation.z, pose.rotation.w]
            case .scale: values = [pose.scale.x, pose.scale.y, pose.scale.z]
            case .weights: values = player.morphWeights[node]
            }
            for component in 0..<width { result[component].append([Float(time), values[component]]) }
        }
        return result
    }
}

private struct EditorAnimationCurveInput: UIViewRepresentable {
    let select: (Point) -> Void
    func makeUIView(in _: Context) -> EditorAnimationCurveInputView {
        let view = EditorAnimationCurveInputView(frame: .zero)
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: EditorAnimationCurveInputView, in _: Context) { view.select = select }
}

private final class EditorAnimationCurveInputView: UIView {
    var select: ((Point) -> Void)?
    override func onMouseEvent(_ event: MouseEvent) {
        if event.button == .left, event.phase == .began { select?(event.mousePosition) }
    }
}
