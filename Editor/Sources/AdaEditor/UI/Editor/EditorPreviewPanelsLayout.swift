@_spi(AdaEngine) import AdaEngine
import Observation

@Observable
@MainActor
final class EditorPreviewResizeState {
    private(set) var width = EditorPreviewSplitLayout.defaultPreviewWidth
    @ObservationIgnored private var dragStart: Float?

    func resize(translation: Float, availableWidth: Float) {
        let start = dragStart ?? EditorPreviewSplitLayout.previewWidth(requestedWidth: width, availableWidth: availableWidth)
        dragStart = start
        width = EditorPreviewSplitLayout.previewWidth(requestedWidth: start - translation, availableWidth: availableWidth)
    }

    func endDrag() {
        dragStart = nil
    }
}

struct EditorPreviewPanelsLayout: Layout {
    let state: EditorPreviewResizeState

    func sizeThatFits(_ proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard subviews.count == 3 else {
            return
        }
        let previewWidth = EditorPreviewSplitLayout.previewWidth(requestedWidth: state.width, availableWidth: bounds.width)
        let divider = min(bounds.width, EditorPreviewSplitLayout.dividerWidth)
        let editorWidth = max(0, bounds.width - divider - previewWidth)
        let hitSize = AdaEngineStyleLayoutSpec.dividerHitSize
        let positions = [Float(0), editorWidth + divider, editorWidth - (hitSize - divider) / 2]
        for (index, width) in [editorWidth, previewWidth, hitSize].enumerated() {
            var childProposal = proposal
            childProposal.width = width
            childProposal.height = bounds.height
            subviews[index].place(at: Point(bounds.minX + positions[index], bounds.minY), anchor: .topLeading, proposal: childProposal)
        }
    }
}
