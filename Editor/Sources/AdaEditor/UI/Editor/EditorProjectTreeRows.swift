@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

@MainActor @Observable
final class EditorProjectTreeRowSelection {
    var isActive: Bool

    init(isActive: Bool) { self.isActive = isActive }
}

/// Isolate selection observation to a row, outside the tree's geometry builder.
struct EditorProjectTreeSelectionRow<Content: View>: View {
    let item: EditorProjectSidebarViewModel.Item
    let selection: EditorProjectTreeRowSelection
    let content: (EditorProjectSidebarViewModel.Item) -> Content

    var body: some View {
        var current = item
        current.isActive = selection.isActive
        return content(current)
    }
}

/// Keeps departing rows alive until their disclosure transition finishes.
@MainActor @Observable
final class EditorProjectTreePresentation {
    typealias Item = EditorProjectSidebarViewModel.Item
    nonisolated static let duration: Double = 0.18
    nonisolated static let rowHeight: Float = 28

    struct Row: Identifiable {
        let item: Item
        let fraction: Float
        let isVisible: Bool
        var id: String { item.id }
        var height: Float { EditorProjectTreePresentation.rowHeight * fraction }
    }

    private struct Entry {
        var item: Item
        var start: Float
        var visible: Bool
    }

    private var entries: [Entry]
    private var startedAt: Date?
    var isAnimating: Bool { startedAt != nil }

    init(items: [Item]) {
        entries = items.map { Entry(item: $0, start: 1, visible: true) }
    }

    func rows(at date: Date) -> [Row] {
        let elapsed = startedAt.map { max(0, date.timeIntervalSince($0)) } ?? Self.duration
        let progress = Float(min(1, elapsed / Self.duration))
        let eased = progress * progress * (3 - 2 * progress)
        return entries.map { entry in
            let target: Float = entry.visible ? 1 : 0
            return Row(item: entry.item, fraction: entry.start + (target - entry.start) * eased, isVisible: entry.visible)
        }
    }

    func reset(to items: [Item]) {
        entries = items.map { Entry(item: $0, start: 1, visible: true) }
        startedAt = nil
    }

    func update(to items: [Item], order: [String], at date: Date) {
        let targets = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let previousTargets = entries.filter(\.visible).map { $0.item.id }
        if previousTargets == items.map(\.id) {
            entries = entries.map { entry in
                var updated = entry
                updated.item = targets[entry.item.id] ?? entry.item
                return updated
            }
            return
        }
        let current = Dictionary(rows(at: date).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        entries = order.compactMap { id in
            guard let item = targets[id] ?? current[id]?.item else { return nil }
            return Entry(item: item, start: current[id]?.fraction ?? 0, visible: targets[id] != nil)
        }
        startedAt = date
    }

    func finishIfNeeded(at date: Date) {
        guard let startedAt, date.timeIntervalSince(startedAt) >= Self.duration else { return }
        reset(to: entries.filter(\.visible).map(\.item))
    }
}

struct EditorProjectTreeRows<RowContent: View>: View {
    let items: [EditorProjectSidebarViewModel.Item]
    let order: [String]
    let onSettled: () -> Void
    let row: (EditorProjectSidebarViewModel.Item) -> RowContent
    @State private var presentation: EditorProjectTreePresentation

    init(
        items: [EditorProjectSidebarViewModel.Item], order: [String], onSettled: @escaping () -> Void,
        @ViewBuilder row: @escaping (EditorProjectSidebarViewModel.Item) -> RowContent
    ) {
        self.items = items
        self.order = order
        self.onSettled = onSettled
        self.row = row
        self._presentation = State(wrappedValue: EditorProjectTreePresentation(items: items))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !presentation.isAnimating)) { context in
            let rows = presentation.rows(at: context.date)
            LazyVStack(rows, alignment: .leading, spacing: 0, estimatedRowHeight: 28, rowHeight: { $0.height }) { entry in
                row(entry.item)
                    .opacity(entry.fraction)
                    .frame(height: entry.height, alignment: .topLeading)
                    .mask(RectangleShape())
                    .allowsHitTesting(entry.isVisible)
                    .accessibilityIdentifier("AdaEditor.ProjectTree.Row.\(entry.item.relativePath)")
            }
            .onChange(of: context.date) { _, date in presentation.finishIfNeeded(at: date) }
        }
        .onChange(of: items) { _, items in
            presentation.update(to: items, order: order, at: Date())
        }
        .onChange(of: presentation.isAnimating) { _, animating in if !animating { onSettled() } }
    }
}
