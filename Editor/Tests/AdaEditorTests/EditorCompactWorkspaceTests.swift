@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Math
import Testing

@testable import AdaEditor

@Suite("Compact workspace edge cases", .serialized)
@MainActor
struct EditorCompactWorkspaceTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "CompactWorkspaceTests")))
        }
    }

    @Test("the dock remains reachable when the sidebars consume the editor column")
    func dockRemainsReachableWithWideSidebars() throws {
        let model = EditorViewModel(project: nil)
        model.showLeftPanel = true
        model.showRightPanel = true
        model.showBottomPanel = true
        let container = UIContainerView(
            rootView: EditorWorkspaceView(
                viewModel: model,
                leftPanel: { Color.red },
                mainPanel: { Color.blue },
                rightPanel: { Color.green },
                bottomPanel: { Color.gray.accessibilityIdentifier("test.dock") }
            )
            .theme(.adaEditor)
        )
        // 260 + 300 points of default sidebar widths leaves the center without
        // enough room for the dock once the vertical dividers are accounted for.
        container.frame = Rect(x: 0, y: 0, width: 560, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let dock = try container.uiNode(matching: .accessibilityIdentifier("test.dock")).absoluteFrame
        let handle = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Workspace.ResizeBottom")).absoluteFrame
        #expect(dock.width == container.frame.width)
        #expect(dock.height > 0)
        #expect(handle.width == dock.width)

        #if os(macOS) || os(Windows) || os(Linux)
        let leftID = "AdaEditor.Workspace.ResizeLeft"
        let rightID = "AdaEditor.Workspace.ResizeRight"
        let left = try container.uiNode(matching: .accessibilityIdentifier(leftID)).absoluteFrame
        let right = try container.uiNode(matching: .accessibilityIdentifier(rightID)).absoluteFrame
        #expect(left.width == 8)
        #expect(right.width == 8)
        #expect(left.maxX <= right.minX)
        let leftHit = try #require(container.uiHitTest(at: Point(left.maxX - 1, left.midY)))
        let rightHit = try #require(container.uiHitTest(at: Point(right.minX + 1, right.midY)))
        #expect(leftHit.path.contains { $0.accessibilityIdentifier == leftID })
        #expect(rightHit.path.contains { $0.accessibilityIdentifier == rightID })
        #endif
    }
}
