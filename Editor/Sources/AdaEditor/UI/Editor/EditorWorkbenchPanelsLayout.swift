@_spi(AdaEngine) import AdaEngine
import Observation

@Observable
@MainActor
final class EditorWorkbenchResizeState {
    private(set) var fraction: Float = 0.5
    @ObservationIgnored private var dragStart: Float?

    func resize(translation: Float, availableWidth: Float, dividerWidth: Float = AdaEngineStyleLayoutSpec.dividerHitSize) {
        let width = max(0, availableWidth - dividerWidth)
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
    let state: EditorWorkbenchResizeState
    var dividerWidth = AdaEngineStyleLayoutSpec.dividerHitSize

    func sizeThatFits(_ proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard subviews.count == 3 else {
            return
        }
        let divider = min(max(0, bounds.width), dividerWidth)
        let available = max(0, bounds.width - divider)
        let minimum = min(240, available / 2)
        let left = min(max(available * state.fraction, minimum), available - minimum)
        let hitSize = AdaEngineStyleLayoutSpec.dividerHitSize
        let positions = [Float(0), left + divider, left - (hitSize - divider) / 2]
        for (index, width) in [left, available - left, hitSize].enumerated() {
            var childProposal = proposal
            childProposal.width = width
            childProposal.height = bounds.height
            subviews[index].place(at: Point(bounds.minX + positions[index], bounds.minY), anchor: .topLeading, proposal: childProposal)
        }
    }
}
