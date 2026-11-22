//
//  EditorWorkspaceView.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 18.05.2026.
//

@_spi(AdaEngine) import AdaEngine
@_spi(AdaEngine) import AdaUI

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
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            // The layout handles width changes without rerunning panel builders.
            // swiftlint:disable:next redundant_discardable_let
            let _ = resizeState.topologyRevision
            let layout = resizeState.layout(in: geometry.size, viewModel: viewModel)
            // Keep the thin dividers independent of the wider hit targets.
            EditorWorkspacePanelsLayout(state: resizeState, viewModel: viewModel)(
                invalidation: resizeState.geometryInvalidation
            ) {
                if layout.showsLeftPanel {
                    leftPanel()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
                mainPanel()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                if layout.showsRightPanel {
                    rightPanel()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
                if layout.showsBottomPanel {
                    bottomPanel()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
                if AdaEngineStyleLayoutSpec.usesCompactWorkspace && layout.showsLeftPanel {
                    verticalDivider
                }
                if AdaEngineStyleLayoutSpec.usesCompactWorkspace && layout.showsRightPanel {
                    verticalDivider
                }
                if layout.showsLeftPanel {
                    resizeHandle(.left, size: geometry.size)
                }
                if layout.showsRightPanel {
                    resizeHandle(.right, size: geometry.size)
                }
                if layout.showsBottomPanel {
                    resizeHandle(.bottom, size: geometry.size)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    }

    private var verticalDivider: some View {
        RectangleShape()
            .fill(theme.editorColors.border)
            .frame(width: EditorWorkspaceLayout.dividerSize)
            .allowsHitTesting(false)
    }

    private func resizeHandle(_ panel: EditorWorkspaceResizeState.Panel, size: Size) -> some View {
        EditorResizeHandle(
            axis: panel == .bottom ? .vertical : .horizontal,
            onResize: { resizeState.resize(panel, translation: $0, in: size, viewModel: viewModel) },
            onResizeEnded: { resizeState.endDrag() },
            showsDivider: AdaEngineStyleLayoutSpec.usesCompactWorkspace && panel == .bottom
        )
        .accessibilityIdentifier("AdaEditor.Workspace.Resize\(panel.rawValue)")
    }
}

struct EditorWorkspaceLayout: Equatable {
    static let dividerSize = AdaEngineStyleLayoutSpec.workspaceDividerSize
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
        let horizontalHandleWidth = Float((leftPanelWidth > 0 ? 1 : 0) + (rightPanelWidth > 0 ? 1 : 0)) * Self.dividerSize
        mainPanelWidth = max(0, size.width - horizontalHandleWidth - (leftPanelWidth + rightPanelWidth))

        bottomPanelHeight =
            showsBottomPanel
            ? Self.clampedBottomPanelHeight(requestedBottomPanelHeight, in: size)
            : 0
        let verticalHandleHeight = bottomPanelHeight > 0 ? Self.dividerSize : 0
        mainPanelHeight = max(0, size.height - verticalHandleHeight - bottomPanelHeight)
    }

    static func clampedBottomPanelHeight(_ height: Float, in size: Size) -> Float {
        let maximumHeight = min(520, size.height - dividerSize - minimumMainPanelHeight)
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
            let handles = Float((left > 0 ? 1 : 0) + (right > 0 ? 1 : 0)) * dividerSize
            let budget = max(0, availableWidth - handles)
            let scale = min(1, budget / (left + right))
            let fittedLeft = left * scale
            let fittedRight = scale < 1 && right > 0 ? budget - fittedLeft : right
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
