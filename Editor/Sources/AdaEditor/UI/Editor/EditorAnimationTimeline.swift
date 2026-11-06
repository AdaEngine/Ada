@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorAnimationTimeline: View {
    let workspace: EditorAnimationAssetWorkspace
    private var model: EditorAnimationTimelineModel { workspace.timeline }
    @Environment(\.theme) private var theme
    @State private var hoverHelp: String?
    @State private var seekDraft: String?
    static let labelsWidth: Float = 190
    static let rulerHeight: Float = 26
    static let rowHeight: Float = 25

    var body: some View {
        VStack(spacing: 3) {
            transport
            filters
            if model.hasUnkeyedPose {
                HStack {
                    Text(L10n.tr("Unkeyed pose")).font(.system(size: 11))
                    action("Insert Key") { model.resolveUnkeyedPose(key: true) }
                    action("Discard") { model.resolveUnkeyedPose(key: false) }
                    action("Cancel") { model.resolveUnkeyedPose(key: false, cancel: true) }
                }
            }
            GeometryReader { geometry in
                if workspace.mode == .curves {
                    EditorAnimationCurves(model: model).frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                let rows = model.rows
                let first = max(0, min(rows.count, Int(model.verticalOffset / Self.rowHeight)))
                let end = min(rows.count, first + max(1, Int(geometry.size.height / Self.rowHeight) + 2))
                ZStack(anchor: .topLeading) {
                    RectangleShape().fill(theme.editorColors.background)
                    Canvas { context, size in draw(rows: rows, first: first, end: end, context: &context, size: size) }
                    EditorAnimationTimelineRowsLayout(first: first, scroll: model.verticalOffset) {
                    ForEach(Array(rows[first..<end]), id: \.id) { row in
                        HStack(spacing: 4) {
                            Text(row.channel == nil ? (model.expandedChannels.contains(row.nodeID) ? "▾" : "▸") : "·")
                            Text(row.label).lineLimit(1)
                            Spacer(minLength: 0)
                        }.font(.system(size: 11)).foregroundColor(model.selectedNodes.contains(row.nodeID) ? theme.editorColors.blue : theme.editorColors.text)
                            .padding(.leading, Float(min(8, row.depth)) * 9 + 4)
                            .frame(width: Self.labelsWidth - 4, height: Self.rowHeight, alignment: .leading)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("AdaEditor.AnimationTimeline.Row.\(row.id)")
                    }
                    }
                    HStack(spacing: 0) {
                        RectangleShape().fill(theme.editorColors.surface).frame(width: Self.labelsWidth, height: Self.rulerHeight)
                        ruler(width: geometry.size.width)
                    }.frame(width: geometry.size.width, height: Self.rulerHeight).allowsHitTesting(false)
                    TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                        let x = Self.labelsWidth + Float((model.time - model.timeOffset)) * model.pixelsPerSecond
                        RectangleShape().fill(theme.editorColors.blue).frame(width: 1, height: geometry.size.height)
                            .offset(x: max(Self.labelsWidth, x)).allowsHitTesting(false)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    EditorAnimationTimelineInput(model: model).frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityIdentifier("AdaEditor.AnimationTimeline.Input")
                }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .mask(RectangleShape())
                    .onAppear { fit(size: geometry.size) }
                    .onChange(of: geometry.size) { _, size in model.viewportSize = size }
                    .onChange(of: model.clip?.id) { _, _ in fit(size: geometry.size) }
                    .onFocusedKeyEvent { event in
                        guard event.status == .down else { return }
                        if event.keyCode == .escape { model.cancelPointer() }
                        if event.keyCode == .delete || event.keyCode == .backspace { model.perform { try model.deleteKeys() } }
                        if event.keyCode == .space { togglePlayback() }
                        if event.modifiers.contains(.command) || event.modifiers.contains(.control), event.keyCode == .z {
                            history(redo: event.modifiers.contains(.shift))
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.error.isEmpty { Text(model.error).font(.system(size: 11)).foregroundColor(.red).lineLimit(2) }
            Text(hoverHelp ?? " ").font(.system(size: 10)).foregroundColor(theme.editorColors.muted).frame(height: 14)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("AdaEditor.AnimationTimeline")
            .onDisappear { model.cancelPointer() }
            .onChange(of: model.clip?.id) { _, _ in seekDraft = nil }
    }

    private var filters: some View {
        HStack(spacing: 5) {
            TextField(L10n.tr("Filter Tracks"), text: Binding(get: { model.search }, set: { model.search = $0 }))
                .textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors, height: 26)).frame(width: 150, height: 26)
                .accessibilityIdentifier("AdaEditor.AnimationTimeline.Filter")
            action(model.selectedOnly ? "All bones" : "Selected only", selected: model.selectedOnly) { model.selectedOnly.toggle() }
                .accessibilityIdentifier("AdaEditor.AnimationTimeline.SelectedOnly")
            action(model.animatedOnly ? "All tracks" : "Animated only", selected: model.animatedOnly) { model.animatedOnly.toggle() }
                .accessibilityIdentifier("AdaEditor.AnimationTimeline.AnimatedOnly")
            EditorEnumField(cases: ["all"] + AnimationLibraryTrack.Channel.allCases.map(\.rawValue),
                selection: Binding(get: { model.channelFilter }, set: { model.channelFilter = $0 }),
                accessibilityID: "AdaEditor.AnimationTimeline.ChannelFilter", labels: ["all": L10n.tr("All channels")])
                .frame(width: 140)
            Spacer(minLength: 0)
        }.frame(height: 27)
    }

    private var transport: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    EditorEnumField(cases: clipIDs, selection: Binding(get: { model.clip?.id ?? "" }, set: { model.selectClip($0) }),
                        accessibilityID: "AdaEditor.AnimationTimeline.Clip", labels: clipLabels, localizesValues: false)
                        .frame(width: min(180, max(100, geometry.size.width * 0.2)))
                    icon("⏮", title: "Stop", id: "Stop") { model.seek(0) }
                    icon("‹◆", title: "Previous Key", id: "PreviousKey") { model.step(-1, byKey: true) }
                    icon("‹", title: "Previous Frame", id: "PreviousFrame") { model.step(-1, byKey: false) }
                    icon(workspace.preview.playsAnimation ? "Ⅱ" : "▶", title: "Play", id: "Play") { togglePlayback() }
                    icon("›", title: "Next Frame", id: "NextFrame") { model.step(1, byKey: false) }
                    icon("◆›", title: "Next Key", id: "NextKey") { model.step(1, byKey: true) }
                    TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                        field("Seconds", text: Binding(get: {
                            seekDraft ?? String(format: "%.4f", model.time)
                        }, set: { workspace.preview.playsAnimation = false; seekDraft = $0 }), width: 75)
                    }.frame(width: 75, height: 25)
                    action("Seek") { model.perform {
                        guard let time = Double(seekDraft ?? String(model.time)), time.isFinite else { throw numericInputError() }
                        model.seek(time)
                        seekDraft = nil
                    } }
                    EditorEnumField(cases: ["0.25", "0.5", "1", "2"], selection: Binding(get: { String(format: "%.3g", model.speed) }, set: {
                        if let speed = Double($0) { model.speed = speed; workspace.preview.playbackSpeed = speed }
                    }), accessibilityID: "AdaEditor.AnimationTimeline.Speed", localizesValues: false).frame(width: 70)
                    if geometry.size.width >= 950 { editControls }
                    Spacer(minLength: 0)
                }
                if geometry.size.width < 950 { HStack(spacing: 5) { editControls; Spacer(minLength: 0) } }
            }
        }.frame(height: model.viewportSize.width >= 950 ? 30 : 62)
    }

    @ViewBuilder private var editControls: some View {
        Text(L10n.tr("Duration")).font(.system(size: 10))
        field("Duration", text: Binding(get: { model.durationText }, set: { model.durationText = $0 }), width: 75)
        action("Apply") { model.perform {
            guard let value = Double(model.durationText), value.isFinite else { throw numericInputError() }
            try model.configureDuration(value)
        } }.disabled(!model.isEditable)
        action(model.clip?.repeats == true ? "Loop: On" : "Loop: Off", selected: model.clip?.repeats == true) {
            model.perform { if let clip = model.clip { try model.apply([.init(kind: .configureClip, clipID: clip.id, repeats: !clip.repeats)]) } }
        }.disabled(!model.isEditable)
        action("Insert Key", prominent: true) { model.perform { try model.insertKeys() } }.disabled(!model.isEditable || model.selectedNodes.isEmpty)
        action("Undo") { history(redo: false) }.disabled(workspace.library?.canUndo != true)
        action("Redo") { history(redo: true) }.disabled(workspace.library?.canRedo != true)
        action("Fit") { fit(size: model.viewportSize) }
        action("Snap", selected: model.snap > 0) { model.snap = model.snap > 0 ? 0 : 1 / 30 }
    }

    private var clipIDs: [String] { (workspace.sourceLibrary?.clips.map(\.id) ?? []) + (workspace.library?.library.clips.map(\.id) ?? []) }
    private var clipLabels: [String: String] {
        var result: [String: String] = [:]
        for clip in workspace.sourceLibrary?.clips ?? [] { result[clip.id] = "◈ " + clip.name }
        for clip in workspace.library?.library.clips ?? [] { result[clip.id] = clip.name }
        return result
    }

    private func fit(size: Size) {
        model.viewportSize = size
        model.timeOffset = 0
        model.pixelsPerSecond = max(1, (size.width - Self.labelsWidth - 20) / Float(max(0.01, model.duration)))
        model.durationText = String(format: "%.5g", model.duration)
    }

    private func ruler(width: Float) -> some View {
        ZStack(anchor: .topLeading) {
            RectangleShape().fill(theme.editorColors.surface)
            ForEach(0..<10, id: \.self) { tick in
                Text(String(format: "%.2f", model.timeOffset + Double(tick) * Double(max(0, width - Self.labelsWidth)) / 10 / Double(max(1, model.pixelsPerSecond))))
                    .font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
                    .offset(x: Float(tick) * max(0, width - Self.labelsWidth) / 10 + 4, y: 6)
            }
        }.frame(width: max(0, width - Self.labelsWidth), height: Self.rulerHeight, alignment: .topLeading)
            .allowsHitTesting(false).accessibilityIdentifier("AdaEditor.AnimationTimeline.Ruler")
    }

    private func draw(rows: [EditorAnimationTimelineModel.Row], first: Int, end: Int, context: inout UIGraphicsContext, size: Size) {
        for index in first..<end {
            let row = rows[index]
            let y = Self.rulerHeight + Float(index) * Self.rowHeight - model.verticalOffset
            context.drawRect(Rect(x: 0, y: y, width: size.width, height: Self.rowHeight - 1),
                color: model.selectedNodes.contains(row.nodeID) ? theme.editorColors.blue.opacity(0.09) : theme.editorColors.surface.opacity(index % 2 == 0 ? 0.5 : 0.15))
            let start = model.timeOffset - 4 / Double(model.pixelsPerSecond)
            let end = model.timeOffset + Double(max(0, size.width - Self.labelsWidth) + 4) / Double(model.pixelsPerSecond)
            for (ref, key) in model.keys(in: row, timeRange: start...end) {
                let selected = model.selectedKeys.contains(ref)
                let time = key.time + (selected ? model.dragDelta : 0)
                let x = Self.labelsWidth + Float(time - model.timeOffset) * model.pixelsPerSecond
                if x >= Self.labelsWidth, x <= size.width {
                    context.drawRect(Rect(x: x - 3, y: y + 9, width: 6, height: 6), color: selected ? .yellow : theme.editorColors.purple)
                }
            }
        }
        let endX = Self.labelsWidth + Float(model.duration - model.timeOffset) * model.pixelsPerSecond
        if endX >= Self.labelsWidth, endX < size.width {
            context.drawRect(Rect(x: endX, y: 0, width: 1, height: size.height), color: theme.editorColors.muted)
        }
        if let rect = model.marquee { context.drawRect(rect, color: theme.editorColors.blue.opacity(0.18)) }
    }

    private func history(redo: Bool) {
        guard let document = workspace.library else { return }
        model.perform {
            if redo { try document.redo(expectedRevision: document.revision) } else { try document.undo(expectedRevision: document.revision) }
            workspace.refreshLibrary()
        }
    }

    private func togglePlayback() {
        guard !model.hasUnkeyedPose else { model.error = L10n.tr("Insert or discard the unkeyed pose first."); return }
        if workspace.preview.playsAnimation { model.timeText = String(format: "%.4f", model.time) }
        workspace.preview.playsAnimation.toggle()
    }

    private func field(_ title: String, text: Binding<String>, width: Float) -> some View {
        TextField(L10n.tr(title), text: text).textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors, height: 25))
            .frame(width: width, height: 25)
    }

    private func icon(_ glyph: String, title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(glyph).font(.system(size: 12)).frame(width: 26, height: 26) }
            .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, selected: id == "Play" && workspace.preview.playsAnimation, horizontalPadding: 0))
            .accessibilityIdentifier("AdaEditor.AnimationTimeline.\(id)")
            .onHover { hoverHelp = $0 ? L10n.tr(title) : nil }
    }

    private func action(_ title: String, prominent: Bool = false, selected: Bool = false, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Text(L10n.tr(title)).font(.system(size: 10)) }
            .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, prominent: prominent, selected: selected))
    }

    private func numericInputError() -> AnimationAuthoringError {
        .init(.invalidKey, itemID: "time", message: L10n.tr("Enter a finite time in seconds."))
    }
}

private struct EditorAnimationTimelineRowsLayout: Layout {
    let first: Int
    let scroll: Float
    func sizeThatFits(_ proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> Size { proposal.replacingUnspecifiedDimensions() }
    func placeSubviews(in bounds: Rect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var childProposal = ProposedViewSize.zero
        childProposal.width = EditorAnimationTimeline.labelsWidth
        childProposal.height = EditorAnimationTimeline.rowHeight
        for (index, child) in subviews.enumerated() {
            child.place(at: Point(bounds.minX, bounds.minY + EditorAnimationTimeline.rulerHeight + Float(first + index) * EditorAnimationTimeline.rowHeight - scroll),
                anchor: .topLeading, proposal: childProposal)
        }
    }
}
