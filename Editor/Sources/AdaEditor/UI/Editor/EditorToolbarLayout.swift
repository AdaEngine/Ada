@_spi(AdaEngine) import AdaEngine

/// Keeps search centered while reserving the measured widths of both control groups.
struct EditorToolbarLayout: Layout {
    let searchWidth: Float

    func sizeThatFits(_ proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard subviews.count == 3 else {
            return
        }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        let clearance = max(leading.width, trailing.width) + 12
        let width = min(searchWidth, max(0, bounds.width - clearance * 2))
        var searchProposal = proposal
        searchProposal.width = width
        searchProposal.height = bounds.height
        let search = subviews[1].sizeThatFits(searchProposal)
        let frames = [
            Rect(x: bounds.minX, y: bounds.midY - leading.height / 2, width: leading.width, height: leading.height),
            Rect(x: bounds.midX - width / 2, y: bounds.midY - search.height / 2, width: width, height: search.height),
            Rect(x: bounds.maxX - trailing.width, y: bounds.midY - trailing.height / 2, width: trailing.width, height: trailing.height),
        ]
        for (index, frame) in frames.enumerated() {
            var childProposal = proposal
            childProposal.width = frame.width
            childProposal.height = frame.height
            subviews[index].place(
                at: frame.origin,
                anchor: .topLeading,
                proposal: childProposal
            )
        }
    }
}
