import AdaEngine
import Foundation

struct EditorPerformanceTimelineView: View {
    let timeline: EditorPerformanceTimeline
    @Environment(\.theme) private var theme
    @State private var zoom: Double = 1
    @State private var startMs: Double = 0
    @State private var selectedEventID: Int?
    @State private var filter = "All"

    private var windowMs: Double { max(0.01, timeline.durationMs / zoom) }
    private var lanes: [EditorPerformanceTimeline.Lane] {
        timeline.lanes.filter {
            filter == "All" || (filter == "Rendering" && ["render_graph", "render_node", "display"].contains($0.category)) ||
                (filter == "ECS" && ["system", "scheduler"].contains($0.category))
        }
    }
    private var selectedEvent: EditorPerformanceTimeline.Event? {
        timeline.events.first { $0.id == selectedEventID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            if let event = selectedEvent {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(event.name) · \(number(event.durationMs)) ms")
                        .foregroundColor(theme.editorColors.text)
                    Text("\(event.category) · start \(number(event.startMs)) ms · end \(number(event.endMs)) ms")
                        .foregroundColor(theme.editorColors.muted)
                    if let graph = event.graph { Text("Graph: \(graph)") }
                    if let type = event.typeName { Text(type).lineLimit(1) }
                    Button("Focus call") {
                        let span = max(0.01, event.durationMs * 4)
                        zoom = min(4096, max(1, timeline.durationMs / span))
                        startMs = max(0, min(event.startMs - windowMs / 4, timeline.durationMs - windowMs))
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .foregroundColor(theme.editorColors.blue)
                }
                .accessibilityIdentifier("AdaEditor.Performance.SelectedEvent")
            }
            if lanes.isEmpty {
                Text("No completed CPU spans in this capture.").foregroundColor(theme.editorColors.muted)
            } else {
                HStack(spacing: 8) {
                    Text("CPU calls").frame(width: 140, alignment: .leading)
                    GeometryReader { geometry in
                        HStack {
                            Text("\(number(startMs)) ms")
                            Spacer()
                            Text("\(number(startMs + windowMs)) ms")
                        }
                        .frame(width: geometry.size.width)
                    }
                }
                .frame(height: 20)
                .foregroundColor(theme.editorColors.muted)
                ForEach(lanes) { lane in
                    laneView(lane)
                }
            }
            Text("Elapsed CPU spans; concurrent calls overlap. GPU execution time is not measured.")
                .foregroundColor(theme.editorColors.muted)
        }
        .accessibilityIdentifier("AdaEditor.Performance.Timeline")
    }

    private var controls: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                Text("\(filter) ▾")
                    .contextMenu(opensOnPrimaryAction: true) {
                        ForEach(["All", "Rendering", "ECS"], id: \.self) { value in
                            ContextMenuOption(value, isSelected: value == filter) { filter = value }
                        }
                    }
                control("−") { zoom = max(1, zoom / 2); clampStart() }
                Text("\(Int(zoom))×")
                control("+") { zoom = min(4096, zoom * 2); clampStart() }
                control("‹") { startMs = max(0, startMs - windowMs / 2) }
                control("›") { startMs = min(max(0, timeline.durationMs - windowMs), startMs + windowMs / 2) }
                control("Fit") { zoom = 1; startMs = 0 }
                Text("\(timeline.events.count) calls · \(number(timeline.durationMs)) ms")
                    .foregroundColor(theme.editorColors.muted)
            }
            .frame(height: 26)
        }
    }

    private func laneView(_ lane: EditorPerformanceTimeline.Lane) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lane.title).lineLimit(2).foregroundColor(color(lane.category))
                Text("\(lane.events.count) calls").foregroundColor(theme.editorColors.muted)
            }
            .frame(width: 140, alignment: .leading)
            VStack(spacing: 2) {
                ForEach(Array(lane.rows.indices), id: \.self) { index in
                    eventRow(lane.rows[index], category: lane.category, identifier: "\(lane.id).\(index)")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 3)
    }

    private func eventRow(_ events: [EditorPerformanceTimeline.Event], category: String, identifier: String) -> some View {
        GeometryReader { geometry in
            Canvas { context, size in
                context.drawRect(Rect(x: 0, y: 0, width: size.width, height: size.height), color: theme.editorColors.surface)
                for tick in 0...4 {
                    context.drawRect(Rect(x: Float(tick) * size.width / 4, y: 0, width: 1, height: size.height),
                                     color: theme.editorColors.border.opacity(0.4))
                }
                for event in events where event.endMs >= startMs && event.startMs <= startMs + windowMs {
                    let x = max(0, Float((event.startMs - startMs) / windowMs) * size.width)
                    let end = min(size.width, Float((event.endMs - startMs) / windowMs) * size.width)
                    context.drawRect(Rect(x: x, y: 2, width: max(2, end - x), height: size.height - 4),
                                     color: event.id == selectedEventID ? theme.editorColors.text : color(category).opacity(0.8))
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                let frame = geometry.frame(in: .global)
                let localX = value.location.x - frame.minX
                let time = startMs + Double(localX / max(1, frame.size.width)) * windowMs
                selectedEventID = EditorPerformanceTimeline.hitTest(events: events, timeMs: time,
                                                                   toleranceMs: windowMs * 3 / Double(max(1, geometry.size.width)))?.id
            })
        }
        .frame(height: 24)
        .accessibilityIdentifier("AdaEditor.Performance.Timeline.Row.\(identifier)")
    }

    private func clampStart() { startMs = min(startMs, max(0, timeline.durationMs - windowMs)) }
    private func number(_ value: Double) -> String { String(format: "%.3f", value) }
    private func color(_ category: String) -> Color {
        switch category {
        case "render_node": theme.editorColors.purple
        case "render_graph", "display": .orange
        case "system", "scheduler": .green
        default: theme.editorColors.blue
        }
    }
    private func control(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(DefaultButtonStyle())
            .foregroundColor(theme.editorColors.blue)
            .accessibilityIdentifier("AdaEditor.Performance.Timeline.\(title)")
    }
}
