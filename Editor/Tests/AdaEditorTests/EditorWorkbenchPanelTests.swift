@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Testing
@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorWorkbenchPanelTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World()))
        }
    }

    @Test func performanceMenuIconsKeepTheirFont() {
        let root = UIContainerView(rootView: EditorPerformancePanel(model: EditorPerformanceModel()).theme(.adaEditor))
        root.frame = Rect(x: 0, y: 0, width: 1000, height: 350)
        root.bounds.size = root.frame.size
        root.layoutIfNeeded()
        let context = UIGraphicsContext()
        root.viewTree.rootNode.draw(with: context)
        let fonts = context.getDrawCommands().flatMap { command -> [Font] in
            switch command {
            case let .drawGlyph(glyph, _, _): return [glyph.attributes.font]
            case let .drawText(layout, _, _): return layout.textLines.flatMap { $0.flatMap { $0.map { $0.attributes.font } } }
            default: return []
            }
        }
        #expect(fonts.filter { $0 == AdaEditorMaterialSymbolFont.font(size: 16) }.count >= 3)
    }

    @Test func terminalRendersUnicodeAndSelection() throws {
        let session = EditorTerminalSession()
        session.terminal.feed(text: "\u{1b}[31mHello\u{1b}[0m Привет")
        let view = EditorTerminalView(frame: Rect(x: 17, y: 29, width: 680, height: 200))
        view.session = session
        view.layoutSubviews()
        session.terminal.updateSelection(session.selection, action: 0, column: 0, row: 0)
        session.terminal.updateSelection(session.selection, action: 1, column: 4, row: 0)
        #expect(session.terminal.selectionText(session.selection) == "Hello")
        let context = UIGraphicsContext()
        view.draw(with: context)
        let glyphCommands = context.getDrawCommands().compactMap { command -> (Glyph, Transform3D)? in
            if case let .drawGlyph(glyph, transform, _) = command { return (glyph, transform) }
            return nil
        }
        #expect(glyphCommands.count == 11)
        for (glyph, transform) in glyphCommands {
            let origin = transform * Vector4(0, 0, 0, 1)
            let bottom = transform * Vector4(glyph.position.x, glyph.position.y, 0, 1)
            let top = transform * Vector4(glyph.position.z, glyph.position.w, 0, 1)
            #expect(origin.x >= 23)
            #expect(origin.y < -29)
            #expect(abs(top.y - bottom.y) < 32)
            #expect(abs(top.x - bottom.x) < 32)
        }
        #expect(view.acceptsKeyboardFocus)
    }

    @Test func terminalFillsWorkspaceAndFollowsResize() async throws {
        let model = EditorViewModel(activeOutputTab: "Terminal")
        model.showBottomPanel = true
        let root = UIContainerView(rootView: EditorWorkspaceView(
            viewModel: model,
            leftPanel: { Color.clear }, mainPanel: { Color.clear }, rightPanel: { Color.clear },
            bottomPanel: { EditorBottomPanel(viewModel: model) }
        ).theme(.adaEditor))
        root.frame.size = Size(width: 1200, height: 700)
        root.bounds.size = root.frame.size
        await settle(root)
        let surface = try root.uiNode(matching: .accessibilityIdentifier("AdaEditor.Terminal.Surface")).absoluteFrame
        #expect(surface.width == 1200)
        #expect(surface.height == 180 - 34)
        #expect(surface.maxY == 700)
        #expect(model.terminals.activeSession.terminal.cols == Int((surface.width - 12) / 8.4))
        #expect(model.terminals.activeSession.terminal.rows == Int((surface.height - 8) / 19))

        let handle = try root.uiNode(matching: .accessibilityIdentifier("AdaEditor.Workspace.ResizeBottom")).absoluteFrame
        let start = Point(handle.midX, handle.midY)
        for (phase, point) in [(MouseEvent.Phase.began, start), (.changed, start - Point(0, 120)), (.ended, start - Point(0, 120))] {
            root.onMouseEvent(MouseEvent(window: .empty, button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
            await settle(root)
        }
        let expanded = try root.uiNode(matching: .accessibilityIdentifier("AdaEditor.Terminal.Surface")).absoluteFrame
        #expect(expanded.height == surface.height + 120)
        #expect(expanded.maxY == 700)
        #expect(model.terminals.activeSession.terminal.rows == Int((expanded.height - 8) / 19))

        root.frame.size = Size(width: 900, height: 600)
        root.bounds.size = root.frame.size
        await settle(root)
        let resized = try root.uiNode(matching: .accessibilityIdentifier("AdaEditor.Terminal.Surface")).absoluteFrame
        #expect(resized.width == 900)
        #expect(resized.height == expanded.height)
        #expect(resized.maxY == 600)
        #expect(model.terminals.activeSession.terminal.cols == Int((resized.width - 12) / 8.4))
    }

    @Test func terminalDefaultsAndInverseTextStayReadable() {
        let session = EditorTerminalSession()
        session.terminal.feed(text: "\u{1b}[0mA\u{1b}[7mB\u{1b}[0m")
        let view = EditorTerminalView(frame: Rect(x: 0, y: 0, width: 680, height: 200))
        view.session = session
        view.layoutSubviews()
        let snapshot = session.terminal.makeRenderSnapshot(scope: .full)
        let fg = snapshot.foregroundColor, bg = snapshot.backgroundColor
        let foreground = Color(red: Float(fg.red) / 65535, green: Float(fg.green) / 65535, blue: Float(fg.blue) / 65535)
        let background = Color(red: Float(bg.red) / 65535, green: Float(bg.green) / 65535, blue: Float(bg.blue) / 65535)
        let context = UIGraphicsContext()
        view.draw(with: context)
        let glyphColors = context.getDrawCommands().compactMap { command -> Color? in
            if case let .drawGlyph(glyph, _, _) = command { return glyph.attributes.foregroundColor }
            return nil
        }
        let cellColors = context.getDrawCommands().compactMap { command -> Color? in
            if case let .drawQuad(_, _, color) = command { return color }
            return nil
        }
        #expect(foreground != background)
        #expect(glyphColors == [foreground, background])
        // UIView paints its own backing rectangle before the terminal background and cells.
        #expect(Array(cellColors.dropFirst().prefix(3)) == [background, background, foreground])
    }

    @Test func terminalTabsKeepIndependentBuffersAndUseIcons() async throws {
        let model = EditorViewModel(activeOutputTab: "Terminal")
        let root = UIContainerView(rootView: EditorBottomPanel(viewModel: model)
            .environment(\.metrics, AdaEngineStyleLayoutMetrics(size: Size(width: 1000, height: 350)))
            .theme(.adaEditor))
        root.frame.size = Size(width: 1000, height: 350)
        root.bounds.size = root.frame.size
        await settle(root)
        for tab in ["Problems", "Build", "Tests", "References", "Output", "Performance", "Terminal"] {
            #expect(root.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Output.Tab.\(tab)")).isEmpty)
        }
        let first = model.terminals.activeSession
        first.terminal.feed(text: "FIRST BUFFER")
        _ = try root.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Terminal.New"))
        await settle(root)
        let second = model.terminals.activeSession
        #expect(first !== second)
        #expect(model.terminals.sessions.count == 2)
        second.terminal.feed(text: "SECOND BUFFER")
        _ = try root.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Terminal.Tab.\(first.id)"))
        await settle(root)
        #expect(model.terminals.activeSession === first)
        #expect(String(decoding: first.terminal.getBufferAsData(), as: UTF8.self).contains("FIRST BUFFER"))
        #expect(!String(decoding: first.terminal.getBufferAsData(), as: UTF8.self).contains("SECOND BUFFER"))
        let context = UIGraphicsContext()
        root.viewTree.rootNode.draw(with: context)
        let fonts = context.getDrawCommands().compactMap { command -> Font? in
            if case let .drawGlyph(glyph, _, _) = command { return glyph.attributes.font }
            return nil
        }
        #expect(fonts.filter { $0 == AdaEditorMaterialSymbolFont.font(size: 16) }.count >= 8)
        _ = try root.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Terminal.Close.\(first.id)"))
        await settle(root)
        #expect(model.terminals.activeSession === second)
        #expect(model.terminals.sessions.count == 1)
        model.selectOutputTab("Build")
        await settle(root)
        #expect(root.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Output.Tab.Tests")).count == 1)
        model.selectOutputTab("Terminal")
        await settle(root)
        #expect(model.terminals.activeSession === second)
        #expect(String(decoding: second.terminal.getBufferAsData(), as: UTF8.self).contains("SECOND BUFFER"))
    }

    private func settle<V: View>(_ root: UIContainerView<V>) async {
        for _ in 0..<10 {
            await Task.yield()
            root.update(1.0 / 60)
            root.layoutIfNeeded()
        }
    }
}
