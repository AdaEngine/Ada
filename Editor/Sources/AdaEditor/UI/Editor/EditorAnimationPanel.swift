@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

struct EditorAnimationPanel: View {
    let viewModel: EditorViewModel

    @Environment(\.metrics) private var metrics
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelToolbar
            RectangleShape().fill(theme.editorColors.border.opacity(0.65)).frame(height: 1)
            panelContent
        }
        .background {
            RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner)
                .fill(theme.editorColors.surfaceElevated)
        }
        .mask(RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner))
        .accessibilityIdentifier("AdaEditor.Animator.Panel")
    }

    private var panelToolbar: some View {
        HStack(spacing: 7) {
            Text("ANIMATOR")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.editorColors.muted)
            transportButton(
                glyph: viewModel.animationPanel.isPlaying ? "\u{E034}" : "\u{E037}",
                identifier: "AdaEditor.Animator.Play"
            ) {
                if let clip = viewModel.selectedAnimationClip {
                    viewModel.animationPanel.togglePlayback(duration: clip.duration)
                    if viewModel.animationPanel.isPlaying, clip.tracks.contains(where: EditorAchievementRules.hasMotion) {
                        viewModel.workbench.achievements?.record([.animation: 1])
                    }
                }
            }
            transportButton(glyph: "\u{E045}", identifier: "AdaEditor.Animator.AddKeyframe") {
                viewModel.addAnimationKeyframe()
            }
            .disabled(viewModel.selectedAnimationTrack == nil)
            transportButton(glyph: "\u{E872}", identifier: "AdaEditor.Animator.DeleteKeyframe") {
                viewModel.removeSelectedAnimationKeyframe()
            }
            .disabled(viewModel.selectedAnimationKeyframe == nil)

            if let clip = viewModel.selectedAnimationClip {
                TextField("Clip name", text: clipNameBinding(clip))
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.text)
                    .frame(width: 126, height: 24)
                    .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.background))

                labeledField("Duration", text: clipDurationBinding(clip), width: 60)

                cycleButton(title: clip.repeatMode.title, identifier: "AdaEditor.Animator.RepeatMode") {
                    let modes = EditorAnimationRepeatMode.allCases
                    let index = modes.firstIndex(of: clip.repeatMode) ?? 0
                    viewModel.updateSelectedAnimationClip(repeatMode: modes[(index + 1) % modes.count])
                }
            }

            Spacer()
            modeButton(.timeline)
            modeButton(.curves)
        }
        .padding(.horizontal, 8)
        .frame(height: 35)
        .background(theme.editorColors.surface)
    }

    @ViewBuilder
    private var panelContent: some View {
        if viewModel.workbench.activeSceneDocument == nil {
            emptyState(title: "Open a scene to edit keyframe animations", actionTitle: nil, action: {})
        } else if let clip = viewModel.selectedAnimationClip {
            HStack(spacing: 0) {
                clipList(selectedClip: clip)
                RectangleShape().fill(theme.editorColors.border.opacity(0.65)).frame(width: 1)
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.animationPanel.mode == .timeline {
                        timeline(clip)
                    } else {
                        curveEditor(clip)
                    }
                    if let track = viewModel.selectedAnimationTrack {
                        RectangleShape().fill(theme.editorColors.border.opacity(0.55)).frame(height: 1)
                        selectionInspector(clip: clip, track: track)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            emptyState(title: "No animation clips for the selected scene", actionTitle: "Create Clip") {
                viewModel.addAnimationClip()
            }
        }
    }

    private func clipList(selectedClip: EditorAnimationClip) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("CLIPS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.editorColors.muted)
                Spacer()
                compactTextButton("+") { viewModel.addAnimationClip() }
                compactTextButton("−") { viewModel.removeSelectedAnimationClip() }
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(viewModel.activeAnimationClips, id: \.id) { clip in
                        Button(action: { viewModel.animationPanel.selectClip(clip) }) {
                            HStack(spacing: 5) {
                                Text("\u{E71C}")
                                    .font(AdaEditorMaterialSymbolFont.font(size: 13))
                                Text(clip.name)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .foregroundColor(clip.id == selectedClip.id ? theme.editorColors.text : theme.editorColors.muted)
                            .padding(.horizontal, 6)
                            .frame(height: 25)
                            .background(
                                RoundedRectangleShape(cornerRadius: 5)
                                    .fill(clip.id == selectedClip.id ? theme.editorColors.blue.opacity(0.18) : Color.clear)
                            )
                        }
                        .buttonStyle(DefaultButtonStyle())
                    }
                }
            }
        }
        .padding(7)
        .frame(width: 150)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(theme.editorColors.surface.opacity(0.66))
    }

    private func timeline(_ clip: EditorAnimationClip) -> some View {
        HStack(spacing: 0) {
            trackList(clip)
            GeometryReader { geometry in
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let playhead = viewModel.animationPanel.displayedPlayhead(now: context.date, duration: clip.duration)
                    Canvas { context, size in
                        drawTimeline(clip, playhead: playhead, context: &context, size: size)
                    }
                    .gesture(scrubGesture(duration: clip.duration, width: geometry.size.width))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.editorColors.background.opacity(0.72))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func trackList(_ clip: EditorAnimationClip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                if let property = EditorAnimationProperty.allCases.first(where: { candidate in
                    !clip.tracks.contains { $0.property == candidate }
                }) {
                    viewModel.addAnimationTrack(property)
                }
            }) {
                HStack(spacing: 4) {
                    Text("+ Track").font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Text("\u{E5CF}").font(AdaEditorMaterialSymbolFont.font(size: 13))
                }
                .foregroundColor(theme.editorColors.blue)
                .padding(.horizontal, 7)
                .frame(height: EditorAnimationPanelDrawing.rulerHeight)
            }
            .buttonStyle(DefaultButtonStyle())
            .contextMenu {
                ForEach(EditorAnimationProperty.allCases, id: \.rawValue) { property in
                    Button(property.title) { viewModel.addAnimationTrack(property) }
                        .disabled(clip.tracks.contains { $0.property == property })
                }
            }

            ForEach(clip.tracks, id: \.id) { track in
                Button(action: { viewModel.animationPanel.selectTrack(track) }) {
                    HStack(spacing: 5) {
                        Text("◆").font(.system(size: 8))
                        Text(track.property.title).font(.system(size: 10)).lineLimit(1)
                        Spacer()
                    }
                    .foregroundColor(track.id == viewModel.selectedAnimationTrack?.id ? theme.editorColors.text : theme.editorColors.muted)
                    .padding(.horizontal, 7)
                    .frame(height: EditorAnimationPanelDrawing.rowHeight)
                    .background(track.id == viewModel.selectedAnimationTrack?.id ? theme.editorColors.blue.opacity(0.12) : Color.clear)
                }
                .buttonStyle(DefaultButtonStyle())
            }
            Spacer()
        }
        .frame(width: 132)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(theme.editorColors.surface.opacity(0.45))
    }

    private func curveEditor(_ clip: EditorAnimationClip) -> some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let playhead = viewModel.animationPanel.displayedPlayhead(now: context.date, duration: clip.duration)
                Canvas { context, size in
                    drawCurve(viewModel.selectedAnimationTrack, duration: clip.duration, playhead: playhead, context: &context, size: size)
                }
                .gesture(scrubGesture(duration: clip.duration, width: geometry.size.width))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.editorColors.background.opacity(0.72))
    }

    private func selectionInspector(clip _: EditorAnimationClip, track: EditorAnimationTrack) -> some View {
        HStack(spacing: 8) {
            Text(track.property.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.editorColors.muted)
            if let keyframe = viewModel.selectedAnimationKeyframe {
                labeledField("Time", text: keyframeTimeBinding(keyframe), width: 58)
                labeledField("Value", text: keyframeValueBinding(keyframe), width: 68)
                ForEach(EditorAnimationCurve.allCases, id: \.rawValue) { curve in
                    curveButton(curve, selected: keyframe.curveToNext == curve)
                }
                compactTextButton("Delete Key") { viewModel.removeSelectedAnimationKeyframe() }
            } else {
                Text("Drag the playhead, then add a keyframe. Select a key below to edit its value and curve.")
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.muted)
                ForEach(track.keyframes, id: \.id) { keyframe in
                    compactTextButton(EditorAnimationPanelFormatting.time(keyframe.time)) {
                        viewModel.animationPanel.selectKeyframe(keyframe)
                    }
                }
            }
            Spacer()
            compactTextButton("Remove Track") { viewModel.removeSelectedAnimationTrack() }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(theme.editorColors.surface)
    }

    private func emptyState(title: String, actionTitle: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Spacer()
            Text(title).font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
            if let actionTitle {
                compactTextButton(actionTitle, action: action)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func drawTimeline(_ clip: EditorAnimationClip, playhead: Double, context: inout UIGraphicsContext, size: Size) {
        let rulerHeight = EditorAnimationPanelDrawing.rulerHeight
        let rowHeight = EditorAnimationPanelDrawing.rowHeight
        let safeDuration = max(0.01, clip.duration)
        let tickCount = max(2, Int(size.width / 80))
        for tick in 0...tickCount {
            let x = size.width * Float(tick) / Float(tickCount)
            context.drawRect(Rect(x: x, y: 0, width: 1, height: size.height), color: theme.editorColors.border.opacity(tick == 0 ? 0.65 : 0.28))
        }
        context.drawRect(Rect(x: 0, y: rulerHeight - 1, width: size.width, height: 1), color: theme.editorColors.border.opacity(0.65))

        for (trackIndex, track) in clip.tracks.enumerated() {
            let rowY = rulerHeight + Float(trackIndex) * rowHeight
            context.drawRect(Rect(x: 0, y: rowY + rowHeight - 1, width: size.width, height: 1), color: theme.editorColors.border.opacity(0.3))
            for keyframe in track.keyframes {
                let x = size.width * Float(keyframe.time / safeDuration)
                let centerY = rowY + rowHeight * 0.5
                drawKeyframeMarker(
                    x: x,
                    y: centerY,
                    selected: keyframe.id == viewModel.animationPanel.selectedKeyframeID,
                    context: &context
                )
            }
        }
        drawPlayhead(x: size.width * Float(playhead / safeDuration), context: &context, size: size)
    }

    private func drawCurve(
        _ track: EditorAnimationTrack?,
        duration: Double,
        playhead: Double,
        context: inout UIGraphicsContext,
        size: Size
    ) {
        let inset: Float = 12
        let graphHeight = max(1, size.height - inset * 2)
        let graphWidth = max(1, size.width - inset * 2)
        for index in 0...4 {
            let y = inset + graphHeight * Float(index) / 4
            context.drawRect(Rect(x: inset, y: y, width: graphWidth, height: 1), color: theme.editorColors.border.opacity(0.25))
        }
        guard let track, !track.keyframes.isEmpty else {
            return
        }
        let values = track.keyframes.map(\.value)
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let padding = max(0.5, (maximum - minimum) * 0.12)
        let low = minimum - padding
        let high = maximum + padding
        let valueRange = max(0.001, high - low)
        let safeDuration = max(0.01, duration)
        let sampleCount = max(2, Int(graphWidth / 3))
        var path = Path()
        for index in 0...sampleCount {
            let time = safeDuration * Double(index) / Double(sampleCount)
            let value = track.value(at: time) ?? 0
            let point = Point(
                inset + graphWidth * Float(time / safeDuration),
                inset + graphHeight * (1 - Float((value - low) / valueRange))
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        context.stroke(path, with: theme.editorColors.blue, style: StrokeStyle(lineWidth: 2))
        for keyframe in track.keyframes {
            let x = inset + graphWidth * Float(keyframe.time / safeDuration)
            let y = inset + graphHeight * (1 - Float((keyframe.value - low) / valueRange))
            drawKeyframeMarker(x: x, y: y, selected: keyframe.id == viewModel.animationPanel.selectedKeyframeID, context: &context)
        }
        drawPlayhead(x: inset + graphWidth * Float(playhead / safeDuration), context: &context, size: size)
    }

    private func drawKeyframeMarker(x: Float, y: Float, selected: Bool, context: inout UIGraphicsContext) {
        let radius: Float = selected ? 5 : 4
        context.drawRect(
            Rect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2),
            color: selected ? theme.editorColors.purple : theme.editorColors.blue
        )
    }

    private func drawPlayhead(x: Float, context: inout UIGraphicsContext, size: Size) {
        context.drawRect(Rect(x: x - 0.5, y: 0, width: 1, height: size.height), color: theme.editorColors.purple.opacity(0.92))
        context.drawRect(Rect(x: x - 4, y: 0, width: 8, height: 5), color: theme.editorColors.purple)
    }

    private func scrubGesture(duration: Double, width: Float) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let time = duration * Double(min(1, max(0, value.location.x / max(1, width))))
                viewModel.animationPanel.stopPlayback(at: time)
            }
    }

    private func transportButton(glyph: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(AdaEditorMaterialSymbolFont.font(size: 15)).frame(width: 25, height: 25)
        }
        .buttonStyle(EditorAnimationControlButtonStyle(theme: theme))
        .accessibilityIdentifier(identifier)
    }

    private func compactTextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).frame(height: 22)
        }
        .buttonStyle(EditorAnimationControlButtonStyle(theme: theme))
    }

    private func cycleButton(title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 10))
                Text("\u{E5CF}").font(AdaEditorMaterialSymbolFont.font(size: 12))
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
        }
        .buttonStyle(EditorAnimationControlButtonStyle(theme: theme))
        .accessibilityIdentifier(identifier)
    }

    private func modeButton(_ mode: EditorAnimationPanelMode) -> some View {
        let selected = viewModel.animationPanel.mode == mode
        return Button(action: { viewModel.animationPanel.mode = mode }) {
            Text(mode.title)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? theme.editorColors.text : theme.editorColors.muted)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(selected ? theme.editorColors.blue.opacity(0.18) : Color.clear))
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Animator.Mode.\(mode.rawValue)")
    }

    private func curveButton(_ curve: EditorAnimationCurve, selected: Bool) -> some View {
        Button(action: { viewModel.updateSelectedAnimationKeyframe(curve: curve) }) {
            Text(curve.title)
                .font(.system(size: 10))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(selected ? theme.editorColors.blue.opacity(0.2) : Color.clear))
        }
        .buttonStyle(EditorAnimationControlButtonStyle(theme: theme))
    }

    private func labeledField(_ label: String, text: Binding<String>, width: Float) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundColor(theme.editorColors.muted)
            TextField("", text: text)
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.text)
                .frame(width: width, height: 22)
                .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.background))
        }
    }

    private func clipNameBinding(_ clip: EditorAnimationClip) -> Binding<String> {
        Binding(get: { viewModel.selectedAnimationClip?.name ?? clip.name }, set: { viewModel.updateSelectedAnimationClip(name: $0) })
    }

    private func clipDurationBinding(_ clip: EditorAnimationClip) -> Binding<String> {
        Binding(
            get: { EditorAnimationPanelFormatting.number(viewModel.selectedAnimationClip?.duration ?? clip.duration) },
            set: {
                if let value = Double($0) {
                    viewModel.updateSelectedAnimationClip(duration: value)
                }
            }
        )
    }

    private func keyframeTimeBinding(_ keyframe: EditorAnimationKeyframe) -> Binding<String> {
        Binding(
            get: { EditorAnimationPanelFormatting.number(viewModel.selectedAnimationKeyframe?.time ?? keyframe.time) },
            set: {
                if let value = Double($0) {
                    viewModel.updateSelectedAnimationKeyframe(time: value)
                }
            }
        )
    }

    private func keyframeValueBinding(_ keyframe: EditorAnimationKeyframe) -> Binding<String> {
        Binding(
            get: { EditorAnimationPanelFormatting.number(viewModel.selectedAnimationKeyframe?.value ?? keyframe.value) },
            set: {
                if let value = Double($0) {
                    viewModel.updateSelectedAnimationKeyframe(value: value)
                }
            }
        )
    }
}

private enum EditorAnimationPanelDrawing {
    static let rulerHeight: Float = 25
    static let rowHeight: Float = 25
}

enum EditorAnimationPanelFormatting {
    static func number(_ value: Double) -> String {
        EditorSceneModelFormatting.format(value)
    }

    static func time(_ value: Double) -> String {
        "\(number(value))s"
    }
}

private struct EditorAnimationControlButtonStyle: ButtonStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.state.isHighlighted ? theme.editorColors.text : theme.editorColors.muted)
            .background(
                RoundedRectangleShape(cornerRadius: 5)
                    .fill(configuration.state.isHighlighted ? theme.editorColors.surfaceElevated : Color.clear)
            )
    }
}
