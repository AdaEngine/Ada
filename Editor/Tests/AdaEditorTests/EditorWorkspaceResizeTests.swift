@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Math
import Testing

@testable import AdaEditor

@Suite("Workspace panel resizing", .serialized)
@MainActor
struct EditorWorkspaceResizeTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "WorkspaceResizeTests")))
        }
    }

    @Test("collapsed panels release their dividers", arguments: [Float(-100), 0, 1, 179])
    func undersizedPanelsCollapse(width: Float) {
        let layout = layout(size: Size(width: 1200, height: 700), left: width, right: width, bottom: 71)
        #expect(!layout.showsLeftPanel)
        #expect(!layout.showsRightPanel)
        #expect(!layout.showsBottomPanel)
        #expect(layout.mainPanelWidth == 1200)
        #expect(layout.mainPanelHeight == 700)
    }

    @Test("minimum usable dimensions remain visible")
    func minimumDimensions() {
        let layout = layout(size: Size(width: 1200, height: 700), left: 180, right: 220, bottom: 72)
        #expect(layout.showsLeftPanel && layout.showsRightPanel && layout.showsBottomPanel)
        #expect(layout.leftPanelWidth == 180)
        #expect(layout.rightPanelWidth == 220)
        #expect(layout.bottomPanelHeight == 72)
    }

    @Test("panels and dividers fit even a tiny workspace", arguments: [Float(0), 1, 7, 8, 100, 187, 188, 219, 220, 227, 228, 400, 416, 600])
    func constrainedWorkspaceFits(extent: Float) {
        let layout = layout(size: Size(width: extent, height: extent))
        let horizontalHandles = Float((layout.showsLeftPanel ? 1 : 0) + (layout.showsRightPanel ? 1 : 0)) * 8
        let verticalHandle: Float = layout.showsBottomPanel ? 8 : 0
        #expect(abs(layout.leftPanelWidth + layout.mainPanelWidth + layout.rightPanelWidth + horizontalHandles - extent) < 0.001)
        #expect(abs(layout.mainPanelHeight + layout.bottomPanelHeight + verticalHandle - extent) < 0.001)
        #expect(!layout.showsLeftPanel || layout.leftPanelWidth >= 180)
        #expect(!layout.showsRightPanel || layout.rightPanelWidth >= 220)
        #expect(!layout.showsBottomPanel || layout.bottomPanelHeight >= 72)
    }

    @Test("window shrinking removes panel content and expanding restores it")
    func windowResize() async throws {
        let model = EditorViewModel(project: nil)
        model.showLeftPanel = true
        model.showRightPanel = true
        model.showBottomPanel = true
        let container = makeContainer(model)
        _ = try container.uiNode(matching: .accessibilityIdentifier("test.right"))
        container.frame.size = Size(width: 100, height: 100)
        container.bounds.size = container.frame.size
        await settle(container)
        for panel in ["left", "right", "bottom"] {
            #expect(throws: (any Error).self) {
                try container.uiNode(matching: .accessibilityIdentifier("test.\(panel)"))
            }
        }
        #expect(try container.uiNode(matching: .accessibilityIdentifier("test.main")).absoluteFrame.size == Size(width: 100, height: 100))
        container.frame.size = Size(width: 1200, height: 700)
        container.bounds.size = container.frame.size
        await settle(container)
        for panel in ["left", "right", "bottom"] {
            _ = try container.uiNode(matching: .accessibilityIdentifier("test.\(panel)"))
        }
    }

    @Test("divider drag collapses the panel and it can be reopened", arguments: ["Left", "Right", "Bottom"])
    func dragAndReopen(panel: String) async throws {
        let model = EditorViewModel(project: nil)
        model.showLeftPanel = true
        model.showRightPanel = true
        model.showBottomPanel = true
        let container = makeContainer(model)
        let original = try container.uiNode(matching: .accessibilityIdentifier("test.\(panel.lowercased())")).absoluteFrame
        let handle = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Workspace.Resize\(panel)")).absoluteFrame
        let start = Point(handle.midX, handle.midY)
        let delta = panel == "Left" ? Point(-240, 0) : panel == "Right" ? Point(280, 0) : Point(0, 160)
        for (phase, point) in [(MouseEvent.Phase.began, start), (.changed, start + delta), (.ended, start + delta)] {
            container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
            await settle(container)
        }
        #expect(throws: (any Error).self) {
            try container.uiNode(matching: .accessibilityIdentifier("test.\(panel.lowercased())"))
        }
        switch panel {
        case "Left":
            #expect(!model.showLeftPanel)
            model.showLeftPanel = true
        case "Right":
            #expect(!model.showRightPanel)
            model.showRightPanel = true
        default:
            #expect(!model.showBottomPanel)
            model.showBottomPanel = true
        }
        await settle(container)
        let reopened = try container.uiNode(matching: .accessibilityIdentifier("test.\(panel.lowercased())")).absoluteFrame
        #expect(reopened == original)
    }

    @Test("continuous divider drag retains panel bodies and follows every pointer movement", arguments: ["Left", "Right", "Bottom"], [false, true])
    func continuousDrag(panel: String, touch: Bool) async throws {
        let model = EditorViewModel(project: nil)
        model.showLeftPanel = true
        model.showRightPanel = true
        model.showBottomPanel = true
        let counter = ResizeBuildCounter()
        let container = UIContainerView(
            rootView: EditorWorkspaceView(
                viewModel: model,
                leftPanel: { ResizeBodyProbe(counter: counter).accessibilityIdentifier("probe.left") },
                mainPanel: { ResizeBodyProbe(counter: counter).accessibilityIdentifier("probe.main") },
                rightPanel: { ResizeBodyProbe(counter: counter).accessibilityIdentifier("probe.right") },
                bottomPanel: { ResizeBodyProbe(counter: counter).accessibilityIdentifier("probe.bottom") }
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 1200, height: 700)
        container.bounds.size = container.frame.size
        await settle(container)
        let beforeBuilds = counter.builds
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Workspace.Resize\(panel)")
        let original = try container.uiNode(matching: selector)
        let start = Point(original.absoluteFrame.midX, original.absoluteFrame.midY)
        let originalMain = try container.uiNode(matching: .accessibilityIdentifier("probe.main"))
        let clock = ContinuousClock()
        let started = clock.now
        for (eventIndex, step) in (Array(0...20) + Array((0..<20).reversed())).enumerated() {
            let delta = Float(step * 3) * (panel == "Left" ? 1 : -1)
            let point = start + (panel == "Bottom" ? Point(0, delta) : Point(delta, 0))
            if touch {
                container.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: eventIndex == 0 ? .began : .moved, time: 0)])
            } else {
                container.onMouseEvent(
                    MouseEvent(
                        window: RID(),
                        button: .left,
                        mousePosition: point,
                        phase: eventIndex == 0 ? .began : .changed,
                        modifierKeys: [],
                        time: 0
                    )
                )
            }
            await settle(container)
            let handle = try container.uiNode(matching: selector)
            #expect(handle.runtimeId == original.runtimeId)
            let actual = panel == "Bottom" ? handle.absoluteFrame.midY : handle.absoluteFrame.midX
            let expected = panel == "Bottom" ? point.y : point.x
            #expect(abs(actual - expected) < 0.001)
        }
        if touch {
            container.onTouchesEvent([TouchEvent(window: .empty, location: start, phase: .ended, time: 0)])
        } else {
            container.onMouseEvent(
                MouseEvent(
                    window: RID(),
                    button: .left,
                    mousePosition: start,
                    phase: .ended,
                    modifierKeys: [],
                    time: 0
                )
            )
        }
        await settle(container)
        #expect(counter.builds == beforeBuilds)
        #expect(try container.uiNode(matching: .accessibilityIdentifier("probe.main")).runtimeId == originalMain.runtimeId)
        print("Workspace \(panel) drag: \(started.duration(to: clock.now)), panel builds: \(counter.builds - beforeBuilds)")
    }

    private func layout(size: Size, left: Float = 260, right: Float = 300, bottom: Float = 180) -> EditorWorkspaceLayout {
        EditorWorkspaceLayout(
            size: size,
            showsLeftPanel: true,
            showsRightPanel: true,
            showsBottomPanel: true,
            requestedLeftPanelWidth: left,
            requestedRightPanelWidth: right,
            requestedBottomPanelHeight: bottom,
            fallbackLeftPanelWidth: 260,
            fallbackRightPanelWidth: 300
        )
    }

    private func makeContainer(_ model: EditorViewModel) -> UIContainerView<some View> {
        let container = UIContainerView(
            rootView: EditorWorkspaceView(
                viewModel: model,
                leftPanel: { Color.red.accessibilityIdentifier("test.left") },
                mainPanel: { Color.blue.accessibilityIdentifier("test.main") },
                rightPanel: { Color.green.accessibilityIdentifier("test.right") },
                bottomPanel: { Color.gray.accessibilityIdentifier("test.bottom") }
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 1200, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        return container
    }

    private func settle<V: View>(_ container: UIContainerView<V>) async {
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
    }
}

@MainActor
private final class ResizeBuildCounter {
    var builds = 0
}

private struct ResizeBodyProbe: View {
    let counter: ResizeBuildCounter
    var body: some View {
        counter.builds += 1
        return Color.blue
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}
