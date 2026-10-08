//
//  AdaEngineStyleLayoutMetrics.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/31/22.
//

@_spi(AdaEngine) import AdaEngine

struct AdaEngineStyleLayoutMetrics: Hashable {
    let size: Size

    var isCompact: Bool {
        size.width < AdaEngineStyleLayoutSpec.compactBreakpoint
    }

    var topToolbarHeight: Float {
        size.height < 520 ? 38 : AdaEngineStyleLayoutSpec.topToolbarHeight
    }

    var footerHeight: Float {
        size.height < 520 ? 20 : AdaEngineStyleLayoutSpec.footerHeight
    }

    var outputPanelHeight: Float {
        size.height < 520 ? 36 : AdaEngineStyleLayoutSpec.outputPanelHeight
    }

    var toolStripWidth: Float {
        size.width < 700 ? 34 : AdaEngineStyleLayoutSpec.toolStripWidth
    }

    var showsProjectSidebar: Bool {
        size.width >= AdaEngineStyleLayoutSpec.projectSidebarBreakpoint
    }

    var showsInspectorSidebar: Bool {
        size.width >= AdaEngineStyleLayoutSpec.inspectorBreakpoint
    }

    var projectSidebarWidth: Float {
        clamped(size.width * 0.22, min: 180, max: AdaEngineStyleLayoutSpec.projectSidebarWidth)
    }

    var inspectorWidth: Float {
        clamped(size.width * 0.22, min: 220, max: AdaEngineStyleLayoutSpec.inspectorWidth)
    }

    var toolbarLeadingSpacerWidth: Float {
        if size.width < 700 {
            return 82
        }
        if isCompact {
            return 160
        }
        return 300
    }

    var toolbarWindowControlClearance: Float {
        60
    }

    var toolbarProjectSwitcherWidth: Float {
        if size.width < 700 {
            return 32
        }
        if isCompact {
            return 72
        }
        return 200
    }

    var toolbarSearchWidth: Float {
        let rightControlWidth: Float = (showsToolbarSceneName ? 92 : 0) + toolbarRunDestinationWidth + toolbarRunControlsWidth + 36
        let reservedSideWidth = max(toolbarLeadingSpacerWidth, rightControlWidth)
        let availableWidth = size.width - reservedSideWidth * 2
        let minimumWidth: Float = size.width < 520 ? 120 : 180
        return clamped(availableWidth, min: minimumWidth, max: 520)
    }

    var workspaceSpacer: Float = 4

    var panelSpacing: Float {
        size.width < 700 ? 6 : AdaEngineStyleLayoutSpec.panelSpacing
    }

    var showsToolbarSceneName: Bool {
        size.width >= 760
    }

    var toolbarRunDestinationWidth: Float {
        96
    }

    var toolbarRunControlsWidth: Float {
        98
    }

    var workbenchWidth: Float {
        let projectWidth = showsProjectSidebar ? projectSidebarWidth : 0
        let inspectorSidebarWidth = showsInspectorSidebar ? inspectorWidth : 0
        return max(0, size.width - toolStripWidth * 2 - projectWidth - inspectorSidebarWidth)
    }

    var aiFlightBoxWidth: Float {
        let availableWidth = max(200, workbenchWidth - 28)
        let desiredWidth = isCompact ? AdaEngineStyleLayoutSpec.aiFlightBoxCompactWidth : AdaEngineStyleLayoutSpec.aiFlightBoxWidth
        let minimumWidth = min(280, availableWidth)
        return clamped(availableWidth, min: minimumWidth, max: desiredWidth)
    }

    var aiFlightBoxHeight: Float {
        if size.height < 440 {
            return 94
        }
        if size.height < 560 {
            return 118
        }
        return AdaEngineStyleLayoutSpec.aiFlightBoxHeight
    }

    var showsAIHeader: Bool {
        size.height >= 440 && aiFlightBoxWidth >= 320
    }

    var showsAIChips: Bool {
        size.height >= 500 && aiFlightBoxWidth >= 360
    }

    var visibleAIChips: [String] {
        if aiFlightBoxWidth < 470 {
            return Array(AdaEngineStyleContent.aiChips.prefix(2))
        }
        return AdaEngineStyleContent.aiChips
    }

    var panelsRoundedCorner: Float = 12

    var outputTabs: [String] {
        if size.width < 620 {
            return ["Problems", "Output", "Performance"]
        }
        if size.width < 900 {
            return ["Problems", "Build", "Output", "Performance"]
        }
        return AdaEngineStyleContent.outputTabs
    }

    var outputTabHorizontalPadding: Float {
        size.width < 760 ? 8 : 12
    }

    var showsFooterRight: Bool {
        size.width >= 620
    }

    func gridTopPadding(for viewportSize: Size) -> Float {
        clamped(viewportSize.height * 0.30, min: 22, max: 270)
    }

    func gridBottomPadding(for viewportSize: Size) -> Float {
        clamped(viewportSize.height * 0.12, min: 28, max: 88)
    }

    func gridHorizontalPadding(for viewportSize: Size) -> Float {
        clamped(viewportSize.width * 0.06, min: 18, max: 58)
    }

    func gridRowSpacing(for viewportSize: Size) -> Float {
        let usableHeight = max(0, viewportSize.height - gridTopPadding(for: viewportSize) - gridBottomPadding(for: viewportSize))
        return clamped(usableHeight / 13, min: 14, max: 34)
    }

    func gridColumnSpacing(for viewportSize: Size) -> Float {
        let usableWidth = max(0, viewportSize.width - gridHorizontalPadding(for: viewportSize) * 2)
        return clamped(usableWidth / 17, min: 18, max: 48)
    }

    func gizmoScale(for viewportSize: Size) -> Float {
        clamped(Swift.min(viewportSize.width / 900, viewportSize.height / 520), min: 0.55, max: 1)
    }

    func gizmoTopPadding(for viewportSize: Size) -> Float {
        clamped(viewportSize.height * 0.24, min: 48, max: 180)
    }

    private func clamped(_ value: Float, min lowerBound: Float, max upperBound: Float) -> Float {
        Swift.max(lowerBound, Swift.min(value, upperBound))
    }
}

extension EnvironmentValues {
    @Entry var metrics: AdaEngineStyleLayoutMetrics = AdaEngineStyleLayoutMetrics(size: .zero)
}
