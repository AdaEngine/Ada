import Foundation
import MCP

/// CPU spans from the same Chrome Trace payload used by the capture exporter.
struct EditorPerformanceTimeline {
    struct Event: Identifiable {
        let id: Int
        let name: String
        let category: String
        let graph: String?
        let typeName: String?
        let startMs: Double
        let durationMs: Double
        var endMs: Double { startMs + durationMs }
    }

    struct Lane: Identifiable {
        let id: String
        let title: String
        let category: String
        let events: [Event]
        /// Overlapping calls occupy separate rows, including concurrent ECS calls.
        let rows: [[Event]]
    }

    let events: [Event]
    let durationMs: Double
    let lanes: [Lane]

    init(trace: Value?) {
        let values = trace?.objectValue?["traceEvents"]?.arrayValue ?? []
        var parsed: [Event] = []
        for (index, value) in values.enumerated() {
            guard let object = value.objectValue,
                  object["ph"]?.stringValue == "X",
                  let name = object["name"]?.stringValue,
                  let start = object["ts"]?.doubleValue,
                  let duration = object["dur"]?.doubleValue,
                  start.isFinite, duration.isFinite, duration >= 0,
                  (start + duration).isFinite else {
                continue
            }
            let arguments = object["args"]?.objectValue
            parsed.append(Event(
                id: index, name: name, category: object["cat"]?.stringValue ?? "other",
                graph: arguments?["ada.render.graph"]?.stringValue,
                typeName: arguments?["ada.render.node_type"]?.stringValue,
                startMs: start / 1000, durationMs: duration / 1000
            ))
        }
        let origin = parsed.map(\.startMs).min() ?? 0
        events = parsed.map {
            Event(id: $0.id, name: $0.name, category: $0.category, graph: $0.graph, typeName: $0.typeName,
                  startMs: $0.startMs - origin, durationMs: $0.durationMs)
        }.sorted { $0.startMs == $1.startMs ? $0.id < $1.id : $0.startMs < $1.startMs }
        durationMs = events.map(\.endMs).max() ?? 0
        let groups = Dictionary(grouping: events) { event in
            // Length-prefixed components keep graph/node names containing separators distinct.
            [event.category, event.graph ?? "", event.name].map { "\($0.utf8.count):\($0)" }.joined()
        }
        lanes = groups.map { key, events in
            let first = events[0]
            var rows: [[Event]] = []
            for event in events {
                if let row = rows.firstIndex(where: { ($0.last?.endMs ?? 0) <= event.startMs }) {
                    rows[row].append(event)
                } else {
                    rows.append([event])
                }
            }
            return Lane(id: key, title: first.graph.map { "\($0) / \(first.name)" } ?? first.name,
                        category: first.category, events: events, rows: rows)
        }.sorted {
            let left = Self.categoryOrder($0.category)
            let right = Self.categoryOrder($1.category)
            return left == right ? $0.title < $1.title : left < right
        }
    }

    private static func categoryOrder(_ category: String) -> Int {
        ["frame", "render_graph", "render_node", "system", "scheduler", "display", "other"].firstIndex(of: category) ?? 7
    }

    /// Select the narrowest call under the pointer, with a minimum visual hit area.
    static func hitTest(events: [Event], timeMs: Double, toleranceMs: Double) -> Event? {
        events.filter { timeMs >= $0.startMs && timeMs <= max($0.endMs, $0.startMs + toleranceMs) }
            .min { $0.durationMs < $1.durationMs }
    }
}
