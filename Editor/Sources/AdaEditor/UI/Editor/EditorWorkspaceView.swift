//
//  EditorWorkspaceView.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 18.05.2026.
//

@_spi(AdaEngine) import AdaEngine

struct EditorWorkspaceView<
    LeftPanel: View,
    MainPanel: View,
    RightPanel: View,
    BottomPanel: View
>: View {
    let viewModel: EditorViewModel
    @ViewBuilder let leftPanel: () -> LeftPanel
    @ViewBuilder let mainPanel: () -> MainPanel
    @ViewBuilder let rightPanel: () -> RightPanel
    @ViewBuilder let bottomPanel: () -> BottomPanel

    @State private var resizeState = EditorWorkspaceResizeState()

    var body: some View {
        GeometryReader { geometry in
            // Width changes are observed by the layout, not the panel builders.
            // swiftlint:disable:next redundant_discardable_let
            let _ = resizeState.topologyRevision
            let layout = resizeState.layout(in: geometry.size, viewModel: viewModel)
            // Keep seven slots, including empty placeholders for collapsed panels.
            EditorWorkspacePanelsLayout(state: resizeState, viewModel: viewModel) {
                if layout.showsLeftPanel {
                    leftPanel()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
                if layout.showsLeftPanel {
                    resizeHandle(.left, size: geometry.size)
                }
                mainPanel()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                if layout.showsRightPanel {
                    resizeHandle(.right, size: geometry.size)
                }
                if layout.showsRightPanel {
                    rightPanel()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
                if layout.showsBottomPanel {
                    resizeHandle(.bottom, size: geometry.size)
                }
                if layout.showsBottomPanel {
                    bottomPanel()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    }

    private func resizeHandle(_ panel: EditorWorkspaceResizeState.Panel, size: Size) -> some View {
        EditorResizeHandle(
            axis: panel == .bottom ? .vertical : .horizontal,
            onResize: { resizeState.resize(panel, translation: $0, in: size, viewModel: viewModel) },
            onResizeEnded: { resizeState.endDrag() }
        )
        .accessibilityIdentifier("AdaEditor.Workspace.Resize\(panel.rawValue)")
    }
}

struct EditorWorkspaceLayout: Equatable {
    static let resizeHandleSize: Float = 8
    static let minimumMainPanelHeight: Float = 140
    static let minimumLeftPanelWidth: Float = 180
    static let minimumRightPanelWidth: Float = 220
    static let minimumBottomPanelHeight: Float = 72

    let leftPanelWidth: Float
    let mainPanelWidth: Float
    let rightPanelWidth: Float
    let mainPanelHeight: Float
    let bottomPanelHeight: Float

    var showsLeftPanel: Bool { leftPanelWidth > 0 }
    var showsRightPanel: Bool { rightPanelWidth > 0 }
    var showsBottomPanel: Bool { bottomPanelHeight > 0 }

    init(
        size: Size,
        showsLeftPanel: Bool,
        showsRightPanel: Bool,
        showsBottomPanel: Bool,
        requestedLeftPanelWidth: Float,
        requestedRightPanelWidth: Float,
        requestedBottomPanelHeight: Float,
        fallbackLeftPanelWidth: Float,
        fallbackRightPanelWidth: Float
    ) {
        let panelWidths = Self.panelWidths(
            availableWidth: max(0, size.width),
            showsLeftPanel: showsLeftPanel,
            showsRightPanel: showsRightPanel,
            requestedLeftPanelWidth: requestedLeftPanelWidth,
            requestedRightPanelWidth: requestedRightPanelWidth,
            fallbackLeftPanelWidth: fallbackLeftPanelWidth,
            fallbackRightPanelWidth: fallbackRightPanelWidth
        )

        leftPanelWidth = panelWidths.left
        rightPanelWidth = panelWidths.right
        let horizontalHandleWidth = Float((leftPanelWidth > 0 ? 1 : 0) + (rightPanelWidth > 0 ? 1 : 0)) * Self.resizeHandleSize
        mainPanelWidth = max(0, size.width - horizontalHandleWidth - leftPanelWidth - rightPanelWidth)

        bottomPanelHeight =
            showsBottomPanel
            ? Self.clampedBottomPanelHeight(requestedBottomPanelHeight, in: size)
            : 0
        let verticalHandleHeight = bottomPanelHeight > 0 ? Self.resizeHandleSize : 0
        mainPanelHeight = max(0, size.height - verticalHandleHeight - bottomPanelHeight)
    }

    static func clampedBottomPanelHeight(_ height: Float, in size: Size) -> Float {
        let maximumHeight = min(520, size.height - resizeHandleSize - minimumMainPanelHeight)
        guard maximumHeight >= minimumBottomPanelHeight, height >= minimumBottomPanelHeight else {
            return 0
        }
        return min(height, maximumHeight)
    }
}

extension EditorWorkspaceLayout {
    private static func panelWidths(
        availableWidth: Float,
        showsLeftPanel: Bool,
        showsRightPanel: Bool,
        requestedLeftPanelWidth: Float,
        requestedRightPanelWidth: Float,
        fallbackLeftPanelWidth: Float,
        fallbackRightPanelWidth: Float
    ) -> (left: Float, right: Float) {
        var left = showsLeftPanel ? resolvedPanelWidth(requestedLeftPanelWidth, fallback: fallbackLeftPanelWidth) : 0
        var right = showsRightPanel ? resolvedPanelWidth(requestedRightPanelWidth, fallback: fallbackRightPanelWidth) : 0
        if left < minimumLeftPanelWidth {
            left = 0
        }
        if right < minimumRightPanelWidth {
            right = 0
        }

        // Reclaim both the content and divider of a collapsed panel before sizing its siblings.
        while left > 0 || right > 0 {
            let handles = Float((left > 0 ? 1 : 0) + (right > 0 ? 1 : 0)) * resizeHandleSize
            let budget = max(0, availableWidth - handles)
            let scale = min(1, budget / (left + right))
            let fittedLeft = left * scale
            let fittedRight = right * scale
            if left > 0 && fittedLeft < minimumLeftPanelWidth {
                left = 0
            } else if right > 0 && fittedRight < minimumRightPanelWidth {
                right = 0
            } else {
                return (fittedLeft, fittedRight)
            }
        }
        return (0, 0)
    }

    private static func resolvedPanelWidth(_ width: Float, fallback: Float) -> Float {
        let resolvedWidth = width.isFinite ? width : fallback
        return max(0, resolvedWidth)
    }
}
