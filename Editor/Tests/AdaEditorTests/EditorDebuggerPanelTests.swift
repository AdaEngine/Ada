@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Math
import Testing

@testable import AdaEditor

@Suite("Editor debugger panel", .serialized)
@MainActor
struct EditorDebuggerPanelTests {
    @Test func tabsAndWatchActionsUseRealViewNodes() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let worlds = AppWorlds(main: World(name: "DebuggerPanelTests"))
            RenderWorldPlugin().setup(in: worlds)
        }
        let debugger = EditorDebugger()
        let container = UIContainerView(rootView: EditorDebugPanel(debugger: debugger))
        container.frame = Rect(x: 0, y: 0, width: 760, height: 280)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let command = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Debug.Command"))
        #expect(command.absoluteFrame.width >= 100)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Debug.Tab.Watches"))
        container.layoutIfNeeded()
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Debug.WatchExpression"))
        debugger.watchExpression = "player.position.x"
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Debug.AddWatch"))
        #expect(debugger.watches == ["player.position.x"])
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Debug.Tab.Console"))
        container.layoutIfNeeded()
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Debug.Command"))
    }
    @Test func enterSubmitsToSelectedDebuggerConsole() async throws {
        let debugger = EditorDebugger()
        let container = makeContainer(debugger)
        debugger.command = "frame variable"
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Debug.Command"))
        container.onKeyEvent(KeyEvent(window: RID(), keyCode: .enter, modifiers: [], status: .down, time: 0, isRepeated: false))
        for _ in 0..<20 { await Task.yield() }
        #expect(debugger.command.isEmpty)
        #expect(debugger.swift.console.contains("> frame variable"))
        #expect(debugger.adaScript.console.isEmpty)
        #expect(throws: (any Error).self) { try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Debug.Send")) }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Debug.Language.AdaScript"))
        debugger.command = "player.position"
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Debug.Command"))
        container.onKeyEvent(KeyEvent(window: RID(), keyCode: .enter, modifiers: [], status: .down, time: 1, isRepeated: false))
        for _ in 0..<20 { await Task.yield() }
        #expect(debugger.adaScript.console.contains("> player.position"))
    }

    @Test("debug controls fit compact and wide panels", arguments: [Float(375), 768, 1440])
    func panelGeometry(width: Float) throws {
        let container = makeContainer(EditorDebugger(), width: width)
        let rail = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Debug.Controls")).absoluteFrame
        let tab = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Debug.Tab.Breakpoints")).absoluteFrame
        let command = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Debug.Command")).absoluteFrame
        let divider = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Debug.CommandDivider")).absoluteFrame
        #expect(rail.width == 40)
        #expect(tab.maxY <= rail.minY)
        #expect(divider.width == width)
        #expect(command.maxX <= width)
        #expect(command.maxY <= 280)
        #expect(command.width > width - 140)
        #expect(try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Debug.pause")).absoluteFrame.maxX <= rail.maxX)
    }

    @Test func debugToolHasIndependentSelectionAndBreakpointRouting() throws {
        let model = EditorViewModel(project: nil)
        let tool = try #require(model.toolStrip.leftBottomTools.first { $0.identifier == "debug" })
        model.selectOutputTab("Output")
        model.activateLeftBottomTool(tool)
        #expect(model.showBottomPanel)
        #expect(model.toolStrip.activeLeftBottomTool == "debug")
        #expect(model.activeOutputTab == "Output")
        model.activateLeftBottomTool(tool)
        #expect(!model.showBottomPanel)
        model.configureDebugger()
        model.debugger.swift.onStopped?()
        #expect(model.showBottomPanel)
        #expect(model.toolStrip.activeLeftBottomTool == "debug")
        #expect(!AdaEngineStyleContent.outputTabs.contains("Debug"))
    }

    @Test func disabledActionsStillExplainThemselvesOnHover() async throws {
        let container = makeContainer(EditorDebugger())
        let frame = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Debug.pause")).absoluteFrame
        container.onMouseEvent(MouseEvent(window: RID(), button: .none, mousePosition: Point(frame.midX, frame.midY), phase: .changed, modifierKeys: [], time: 0))
        try await Task.sleep(for: .milliseconds(600))
        for _ in 0..<10 {
            await Task.yield()
            container.layoutIfNeeded()
        }
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Debug.Tooltip"))
    }

    private func makeContainer(_ debugger: EditorDebugger, width: Float = 760) -> UIContainerView<EditorDebugPanel> {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "DebuggerPanelTests")))
        }
        let container = UIContainerView(rootView: EditorDebugPanel(debugger: debugger))
        container.frame = Rect(x: 0, y: 0, width: width, height: 280)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        return container
    }
}
