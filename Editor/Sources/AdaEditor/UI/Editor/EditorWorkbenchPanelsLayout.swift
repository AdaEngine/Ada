@_spi(AdaEngine) import AdaEngine
import Observation

@Observable
@MainActor
final class EditorWorkbenchResizeState {
    private(set) var fraction: Float = 0.5
    @ObservationIgnored private var dragStart: Float?

    func resize(translation: Float, availableWidth: Float) {
        let width = max(0, availableWidth - EditorWorkbenchPanelsLayout.handleWidth)
        guard width > 0 else {
            return
        }
        let start = dragStart ?? fraction
        dragStart = start
        let minimum = min(240 / width, 0.5)
        fraction = min(max(start + translation / width, minimum), 1 - minimum)
    }

    func endDrag() { dragStart = nil }
}

struct EditorWorkbenchPanelsLayout: Layout {
    static let handleWidth: Float = 8
    let state: EditorWorkbenchResizeState

    func sizeThatFits(_ proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard subviews.count == 3 else {
            return
        }
        let handle = min(max(0, bounds.width), Self.handleWidth)
        let available = max(0, bounds.width - handle)
        let minimum = min(240, available / 2)
        let left = min(max(available * state.fraction, minimum), available - minimum)
        var x = bounds.minX
        for (index, width) in [left, handle, available - left].enumerated() {
            var childProposal = proposal
            childProposal.width = width
            childProposal.height = bounds.height
            subviews[index].place(at: Point(x, bounds.minY), anchor: .topLeading, proposal: childProposal)
            x += width
        }
    }
}
