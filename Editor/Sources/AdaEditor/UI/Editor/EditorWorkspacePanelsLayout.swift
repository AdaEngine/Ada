@_spi(AdaEngine) import AdaEngine
import Observation

@Observable
@MainActor
final class EditorWorkspaceResizeState {
    enum Panel: String {
        case left = "Left"
        case right = "Right"
        case bottom = "Bottom"
    }

    // Only the layout subscribes to per-movement updates. Content subscribes to topology.
    private(set) var layoutRevision: UInt64 = 0
    private(set) var topologyRevision: UInt64 = 0
    @ObservationIgnored private var leftWidth: Float = AdaEngineStyleLayoutSpec.projectSidebarWidth
    @ObservationIgnored private var rightWidth: Float = AdaEngineStyleLayoutSpec.inspectorWidth
    @ObservationIgnored private var bottomHeight: Float = 180
    @ObservationIgnored private var dragStart: Float?

    func layout(in size: Size, viewModel: EditorViewModel) -> EditorWorkspaceLayout {
        EditorWorkspaceLayout(
            size: size,
            showsLeftPanel: viewModel.showLeftPanel,
            showsRightPanel: viewModel.showRightPanel,
            showsBottomPanel: viewModel.showBottomPanel,
            requestedLeftPanelWidth: leftWidth,
            requestedRightPanelWidth: rightWidth,
            requestedBottomPanelHeight: bottomHeight,
            fallbackLeftPanelWidth: AdaEngineStyleLayoutSpec.projectSidebarWidth,
            fallbackRightPanelWidth: AdaEngineStyleLayoutSpec.inspectorWidth
        )
    }

    func resize(_ panel: Panel, translation: Size, in size: Size, viewModel: EditorViewModel) {
        let before = layout(in: size, viewModel: viewModel)
        switch panel {
        case .left:
            let start = dragStart ?? before.leftPanelWidth
            dragStart = start
            let width = start + translation.width
            if width < EditorWorkspaceLayout.minimumLeftPanelWidth {
                viewModel.showLeftPanel = false
                leftWidth = max(start, EditorWorkspaceLayout.minimumLeftPanelWidth)
                dragStart = nil
            } else {
                leftWidth = width
            }
        case .right:
            let start = dragStart ?? before.rightPanelWidth
            dragStart = start
            let width = start - translation.width
            if width < EditorWorkspaceLayout.minimumRightPanelWidth {
                viewModel.showRightPanel = false
                rightWidth = max(start, EditorWorkspaceLayout.minimumRightPanelWidth)
                dragStart = nil
            } else {
                rightWidth = width
            }
        case .bottom:
            let start = dragStart ?? before.bottomPanelHeight
            dragStart = start
            let height = start - translation.height
            if height < EditorWorkspaceLayout.minimumBottomPanelHeight {
                viewModel.showBottomPanel = false
                bottomHeight = start
                dragStart = nil
            } else {
                bottomHeight = EditorWorkspaceLayout.clampedBottomPanelHeight(height, in: size)
            }
        }
        let after = layout(in: size, viewModel: viewModel)
        guard before != after else {
            return
        }
        if before.showsLeftPanel != after.showsLeftPanel
            || before.showsRightPanel != after.showsRightPanel
            || before.showsBottomPanel != after.showsBottomPanel {
            topologyRevision &+= 1
        }
        layoutRevision &+= 1
    }

    func endDrag() {
        dragStart = nil
    }
}

/// Places retained panel subtrees directly; moving a divider does not recreate their views.
struct EditorWorkspacePanelsLayout: Layout {
    let state: EditorWorkspaceResizeState
    let viewModel: EditorViewModel

    func sizeThatFits(_ proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: Rect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        _ = state.layoutRevision
        let layout = state.layout(in: bounds.size, viewModel: viewModel)
        var index = 0
        var x: Float = 0
        func place(width: Float, height: Float, x: Float, y: Float = 0) {
            guard index < subviews.count else {
                return
            }
            var childProposal = ProposedViewSize.zero
            childProposal.width = width
            childProposal.height = height
            subviews[index]
                .place(
                    at: Point(bounds.minX + x, bounds.minY + y),
                    anchor: .topLeading,
                    proposal: childProposal
                )
            index += 1
        }
        let horizontalHandle = EditorWorkspaceLayout.resizeHandleSize
        place(width: layout.leftPanelWidth, height: layout.mainPanelHeight, x: x)
        x += layout.leftPanelWidth
        place(width: layout.showsLeftPanel ? horizontalHandle : 0, height: layout.mainPanelHeight, x: x)
        x += layout.showsLeftPanel ? horizontalHandle : 0
        place(width: layout.mainPanelWidth, height: layout.mainPanelHeight, x: x)
        x += layout.mainPanelWidth
        place(width: layout.showsRightPanel ? horizontalHandle : 0, height: layout.mainPanelHeight, x: x)
        x += layout.showsRightPanel ? horizontalHandle : 0
        place(width: layout.rightPanelWidth, height: layout.mainPanelHeight, x: x)
        let verticalHandle = layout.showsBottomPanel ? EditorWorkspaceLayout.resizeHandleSize : 0
        place(width: bounds.width, height: verticalHandle, x: 0, y: layout.mainPanelHeight)
        place(width: bounds.width, height: layout.bottomPanelHeight, x: 0, y: layout.mainPanelHeight + verticalHandle)
    }
}
