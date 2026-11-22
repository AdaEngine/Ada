@_spi(AdaEngine) import AdaEngine
@_spi(AdaEngine) import AdaUI
import Observation

@Observable
@MainActor
final class EditorWorkspaceResizeState {
    enum Panel: String {
        case left = "Left"
        case right = "Right"
        case bottom = "Bottom"
    }

    // Pointer movement requests layout directly. Content only observes topology changes.
    let geometryInvalidation = LayoutInvalidation()
    private(set) var topologyRevision: UInt64 = 0
    @ObservationIgnored private var leftWidth: Float = AdaEngineStyleLayoutSpec.projectSidebarWidth
    @ObservationIgnored private var rightWidth: Float = AdaEngineStyleLayoutSpec.inspectorWidth
    @ObservationIgnored private var bottomHeight: Float = 180
    @ObservationIgnored private var animatorHeight: Float = 380
    @ObservationIgnored private var animatorWasResized = false
    @ObservationIgnored private var dragStart: Float?

    func layout(in size: Size, viewModel: EditorViewModel) -> EditorWorkspaceLayout {
        EditorWorkspaceLayout(
            size: size,
            showsLeftPanel: viewModel.showLeftPanel,
            showsRightPanel: viewModel.showRightPanel,
            showsBottomPanel: viewModel.showBottomPanel && !viewModel.performance.isExpanded,
            requestedLeftPanelWidth: leftWidth,
            requestedRightPanelWidth: rightWidth,
            requestedBottomPanelHeight: viewModel.toolStrip.activeLeftBottomTool == "animator"
                ? (animatorWasResized ? animatorHeight : min(animatorHeight, max(0, size.height * 0.46))) : bottomHeight,
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
            if viewModel.toolStrip.activeLeftBottomTool == "animator" { animatorWasResized = true }
            let start = dragStart ?? before.bottomPanelHeight
            dragStart = start
            let height = start - translation.height
            if height < EditorWorkspaceLayout.minimumBottomPanelHeight {
                viewModel.showBottomPanel = false
                if viewModel.toolStrip.activeLeftBottomTool == "animator" {
                    animatorHeight = start
                } else {
                    bottomHeight = start
                }
                dragStart = nil
            } else {
                let adjusted = EditorWorkspaceLayout.clampedBottomPanelHeight(height, in: size)
                if viewModel.toolStrip.activeLeftBottomTool == "animator" {
                    animatorHeight = adjusted
                } else {
                    bottomHeight = adjusted
                }
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
        geometryInvalidation.invalidateGeometry()
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
        let layout = state.layout(in: bounds.size, viewModel: viewModel)
        var index = 0
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
        let divider = EditorWorkspaceLayout.dividerSize
        let hitSize = AdaEngineStyleLayoutSpec.dividerHitSize
        let overlap = (hitSize - divider) / 2
        let compact = AdaEngineStyleLayoutSpec.usesCompactWorkspace
        let mainX = layout.leftPanelWidth + (layout.showsLeftPanel ? divider : 0)
        let mainRight = mainX + layout.mainPanelWidth
        let rightX = mainRight + (layout.showsRightPanel ? divider : 0)
        // Very wide sidebars can consume the center. Keep the dock, including
        // its tabs and resize handle, reachable beneath them in this layout.
        let dockInCenter = compact && (layout.mainPanelWidth >= 160 || !layout.showsBottomPanel)
        let sidebarHeight = dockInCenter ? bounds.height : layout.mainPanelHeight
        let dockX = dockInCenter ? mainX : 0
        let dockWidth = dockInCenter ? layout.mainPanelWidth : bounds.width

        place(width: layout.leftPanelWidth, height: sidebarHeight, x: 0)
        place(width: layout.mainPanelWidth, height: layout.mainPanelHeight, x: mainX)
        place(width: layout.rightPanelWidth, height: sidebarHeight, x: rightX)
        place(width: dockWidth, height: layout.bottomPanelHeight, x: dockX, y: layout.mainPanelHeight + divider)

        place(width: compact && layout.showsLeftPanel ? divider : 0, height: sidebarHeight, x: layout.leftPanelWidth)
        place(width: compact && layout.showsRightPanel ? divider : 0, height: sidebarHeight, x: mainRight)

        // If the editor column is too narrow, make room for both mouse targets
        // by moving them outward. The visible seams stay at the panel edges.
        let shift = layout.showsLeftPanel && layout.showsRightPanel
            ? max(0, hitSize - divider - layout.mainPanelWidth) / 2
            : 0
        place(width: layout.showsLeftPanel ? hitSize : 0, height: sidebarHeight, x: layout.leftPanelWidth - overlap - shift)
        place(width: layout.showsRightPanel ? hitSize : 0, height: sidebarHeight, x: mainRight - overlap + shift)
        place(width: dockWidth, height: layout.showsBottomPanel ? hitSize : 0, x: dockX, y: layout.mainPanelHeight - overlap)
    }
}
