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
    nonisolated static let rowHeight: Float = AdaEngineStyleLayoutSpec.usesCompactWorkspace ? 22 : 28
    private static let maxAnimatedVisibilityChanges = 64

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
    @ObservationIgnored private var settledRows: [Row] = []
    private var startedAt: Date?
    private(set) var settledRevision: UInt64 = 0
    var isAnimating: Bool { startedAt != nil }

    init(items: [Item]) {
        entries = items.map { Entry(item: $0, start: 1, visible: true) }
        settledRows = items.map { Row(item: $0, fraction: 1, isVisible: true) }
    }

    func rows(at date: Date) -> [Row] {
        // Observe entry changes even when a settled snapshot already exists.
        let entries = self.entries
        guard let startedAt else {
            return settledRows
        }
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let progress = Float(min(1, elapsed / Self.duration))
        let eased = progress * progress * (3 - 2 * progress)
        return entries.map { entry in
            let target: Float = entry.visible ? 1 : 0
            return Row(item: entry.item, fraction: entry.start + (target - entry.start) * eased, isVisible: entry.visible)
        }
    }

    func reset(to items: [Item]) {
        entries = items.map { Entry(item: $0, start: 1, visible: true) }
        settledRows = items.map { Row(item: $0, fraction: 1, isVisible: true) }
        startedAt = nil
    }

    func update(to items: [Item], order: [String], at date: Date) {
        let targets = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let previousTargets = entries.filter(\.visible).map { $0.item.id }
        if previousTargets == items.map(\.id) {
            if !isAnimating {
                reset(to: items)
                return
            }
            entries = entries.map { entry in
                var updated = entry
                updated.item = targets[entry.item.id] ?? entry.item
                return updated
            }
            return
        }

        // A large folder animated from zero height packs all of its children into
        // the viewport at once and defeats the lazy stack's normal row budget.
        if Set(previousTargets).symmetricDifference(targets.keys).count > Self.maxAnimatedVisibilityChanges {
            settle(to: items)
            return
        }

        let current = Dictionary(rows(at: date).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        entries = order.compactMap { id in
            guard let item = targets[id] ?? current[id]?.item else {
                return nil
            }
            return Entry(item: item, start: current[id]?.fraction ?? 0, visible: targets[id] != nil)
        }
        startedAt = date
    }

    func finishIfNeeded(at date: Date) {
        guard let startedAt, date.timeIntervalSince(startedAt) >= Self.duration else {
            return
        }
        settle(to: entries.filter(\.visible).map(\.item))
    }

    private func settle(to items: [Item]) {
        reset(to: items)
        settledRevision &+= 1
    }
}

struct EditorProjectTreeRows<RowContent: View>: View {
    let items: [EditorProjectSidebarViewModel.Item]
    let order: [String]
    let onSettled: () -> Void
    let row: (EditorProjectSidebarViewModel.Item) -> RowContent
    @State private var presentation: EditorProjectTreePresentation

    init(
        items: [EditorProjectSidebarViewModel.Item],
        order: [String],
        onSettled: @escaping () -> Void,
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
            LazyVStack(rows, alignment: .leading, spacing: 0, estimatedRowHeight: EditorProjectTreePresentation.rowHeight, rowHeight: { $0.height }) { entry in
                row(entry.item)
                    .opacity(entry.fraction)
                    .frame(height: entry.height, alignment: .topLeading)
                    .mask(RectangleShape(), isEnabled: entry.fraction != 1)
                    .allowsHitTesting(entry.isVisible)
                    .accessibilityIdentifier("AdaEditor.ProjectTree.Row.\(entry.item.relativePath)")
            }
            // Reveal after the new row IDs have reached the mounted lazy stack.
            .onChange(of: presentation.settledRevision) { _, _ in onSettled() }
            .onChange(of: context.date) { _, date in presentation.finishIfNeeded(at: date) }
        }
        .onChange(of: items) { _, items in
            presentation.update(to: items, order: order, at: Date())
        }
    }
}
