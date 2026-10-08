//
//  ButtonStyleTests.swift
//  AdaEngine
//

import Testing
@testable import AdaUI
@testable import AdaPlatform
import AdaInput
import AdaUtils
import Math

private struct ButtonStyleCounterKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    fileprivate var buttonStyleCounter: Int {
        get { self[ButtonStyleCounterKey.self] }
        set { self[ButtonStyleCounterKey.self] = newValue }
    }
}

@MainActor
struct ButtonStyleTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func buttonStyle_focusStateSurvivesHoverLeave() {
        let recorder = ButtonStyleStateRecorder()

        let tester = ViewTester {
            Button(action: {}) {
                Text("Tap")
                    .frame(width: 100, height: 44)
            }
            .buttonStyle(RecordingButtonStyle(recorder: recorder))
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 50), button: .left, phase: .began)
        tester.sendMouseEvent(at: Point(100, 50), button: .left, phase: .ended)
        tester.sendMouseEvent(at: Point(100, 50), button: .none, phase: .changed)
        tester.sendMouseEvent(at: Point(10, 10), button: .none, phase: .changed)

        #expect(recorder.states.last?.contains(.focused) == true)
        #expect(recorder.states.last?.contains(.highlighted) == false)
        #expect(recorder.states.last?.contains(.selected) == false)
    }

    @Test
    func buttonStyle_receivesHighlightedStateOnHover() {
        let recorder = ButtonStyleStateRecorder()

        let tester = ViewTester {
            Button(action: {}) {
                Text("Hover")
                    .frame(width: 100, height: 44)
            }
            .buttonStyle(RecordingButtonStyle(recorder: recorder))
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 50), button: .none, phase: .changed)

        #expect(recorder.states.last?.contains(.highlighted) == true)
        #expect(recorder.states.last?.contains(.selected) == false)
    }

    @Test
    func buttonStyle_doesNotRebuildForRepeatedMouseMovesInsideHoveredButton() {
        let recorder = ButtonStyleStateRecorder()

        let tester = ViewTester {
            Button(action: {}) {
                Text("Completion")
                    .frame(width: 140, height: 28)
            }
            .buttonStyle(RecordingButtonStyle(recorder: recorder))
        }
        .setSize(Size(width: 200, height: 80))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 40), button: .none, phase: .changed)
        let rebuildCountAfterEntering = recorder.states.count
        _ = tester.containerView.consumeNeedsDisplay()

        for offset in 0..<20 {
            tester.sendMouseEvent(
                at: Point(90 + Float(offset % 10), 40),
                button: .none,
                phase: .changed
            )
        }

        #expect(recorder.states.count == rebuildCountAfterEntering)
        #expect(recorder.states.last?.contains(.highlighted) == true)
        #expect(!tester.containerView.needsDisplay)
    }

    @Test
    func buttonStyle_movingFromTabIntoBlankAreaDoesNotContinuouslyRedraw() {
        let recorder = ButtonStyleStateRecorder()

        let tester = ViewTester {
            HStack(spacing: 0) {
                Button(action: {}) {
                    Text("main.swift")
                        .frame(width: 120, height: 28)
                }
                .buttonStyle(RecordingButtonStyle(recorder: recorder))
                Spacer()
            }
            .frame(width: 400, height: 36)
        }
        .setSize(Size(width: 400, height: 60))
        .performLayout()

        tester.sendMouseEvent(at: Point(60, 30), button: .none, phase: .changed)
        tester.sendMouseEvent(at: Point(260, 30), button: .none, phase: .changed)
        let rebuildCountAfterLeavingTab = recorder.states.count
        _ = tester.containerView.consumeNeedsDisplay()

        for offset in 0..<20 {
            tester.sendMouseEvent(
                at: Point(240 + Float(offset), 30),
                button: .none,
                phase: .changed
            )
        }

        #expect(recorder.states.count == rebuildCountAfterLeavingTab)
        #expect(!tester.containerView.needsDisplay)
    }

    @Test
    func buttonStyleEnvironmentChangeRebuildsStyleBody() {
        let recorder = ButtonStyleEnvironmentRecorder()

        let tester = ViewTester {
            ButtonStyleEnvironmentHost(recorder: recorder)
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()

        #expect(recorder.values.contains(0))

        tester.sendMouseEvent(at: Point(100, 50), button: .left, phase: .began)
        tester.sendMouseEvent(at: Point(100, 50), button: .left, phase: .ended)
        tester.performLayout()

        #expect(recorder.values.contains(1))
    }

    @Test
    func navigationBarButtonStyleSurvivesEnvironmentUpdatesAndHover() throws {
        let tester = ViewTester {
            NavigationStack {
                Color.clear
                    .navigationTitle("Title")
                    .navigationBarTrailingItems {
                        Button("Edit") {}
                    }
            }
        }
        .setSize(Size(width: 300, height: 200))
        .performLayout()

        let button = try #require(buttonNodes(in: tester.containerView.viewTree.rootNode).first)
        #expect(button.environment.buttonStyle is NavigationBarButtonStyle)

        let buttonFrame = button.absoluteFrame()
        let buttonCenter = Point(
            x: buttonFrame.origin.x + buttonFrame.width * 0.5,
            y: buttonFrame.origin.y + buttonFrame.height * 0.5
        )
        tester.sendMouseEvent(at: buttonCenter, button: .none, phase: .changed)
        tester.sendMouseEvent(at: Point(10, 180), button: .none, phase: .changed)

        let updatedButton = try #require(buttonNodes(in: tester.containerView.viewTree.rootNode).first)
        #expect(updatedButton.environment.buttonStyle is NavigationBarButtonStyle)
    }

    @Test
    func glassButtonStyleEmitsGlassDrawCommand() throws {
        let tester = ViewTester {
            Button("Glass") {}
                .buttonStyle(GlassButtonStyle())
        }
        .setSize(Size(width: 220, height: 120))
        .performLayout()

        let context = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: context)

        let glassConfiguration = try #require(context.getDrawCommands().glassConfigurations.first)
        #expect(glassConfiguration.blurRadius == AdaColorPalette.landingButtonGlass.blurRadius)
        #expect(context.getDrawCommands().containsTextDraw)
    }

    @Test
    func glassButtonStyleUsesPressedGlassWhenSelected() throws {
        let normalGlass = Glass.regular.blurRadius(7)
        let pressedGlass = Glass.interaction.blurRadius(19)

        let tester = ViewTester {
            Button("Press") {}
                .buttonStyle(GlassButtonStyle(glass: normalGlass, highlightedGlass: normalGlass, pressedGlass: pressedGlass))
        }
        .setSize(Size(width: 220, height: 120))
        .performLayout()

        let button = try #require(buttonNodes(in: tester.containerView.viewTree.rootNode).first)
        let buttonFrame = button.absoluteFrame()
        let buttonCenter = Point(
            x: buttonFrame.origin.x + buttonFrame.width * 0.5,
            y: buttonFrame.origin.y + buttonFrame.height * 0.5
        )

        tester.sendMouseEvent(at: buttonCenter, button: .left, phase: .began)

        let context = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: context)

        let glassConfiguration = try #require(context.getDrawCommands().glassConfigurations.first)
        #expect(glassConfiguration.blurRadius == pressedGlass.blurRadius)
    }

    @Test
    func glassButtonStyleScalesUpWhenSelected() throws {
        let tester = ViewTester {
            Button("Press") {}
                .buttonStyle(GlassButtonStyle())
        }
        .setSize(Size(width: 220, height: 120))
        .performLayout()

        let initialContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: initialContext)
        let initialTransform = try #require(initialContext.getDrawCommands().glassTransforms.first)

        let button = try #require(buttonNodes(in: tester.containerView.viewTree.rootNode).first)
        let buttonFrame = button.absoluteFrame()
        let buttonCenter = Point(
            x: buttonFrame.origin.x + buttonFrame.width * 0.5,
            y: buttonFrame.origin.y + buttonFrame.height * 0.5
        )

        tester.sendMouseEvent(at: buttonCenter, button: .left, phase: .began)
        tester.advanceFrame(deltaTime: 0.1)

        let pressedContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: pressedContext)
        let pressedTransform = try #require(pressedContext.getDrawCommands().glassTransforms.first)

        #expect(pressedTransform.x.x > initialTransform.x.x)
        #expect(pressedTransform.y.y > initialTransform.y.y)
    }

    @Test
    func glassButtonStyleKeepsShortCenteredLabelVisuallyCentered() throws {
        let tester = ViewTester {
            Button("Ask Yadev") {}
                .buttonStyle(GlassButtonStyle())
                .frame(width: 320, height: 72)
        }
        .setSize(Size(width: 320, height: 120))
        .performLayout()

        let context = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: context)

        let commands = context.getDrawCommands()
        let minX = try #require(drawnGlyphMinX(in: commands))
        let maxX = try #require(drawnGlyphMaxX(in: commands))
        let visualCenterX = (minX + maxX) / 2

        #expect(abs(visualCenterX - 160) < 2.5)
    }

    @Test
    func buttonHoverInvalidationMarksContainerForRedraw() throws {
        let tester = ViewTester {
            Button(action: {}) {
                Text("Hover")
                    .frame(width: 100, height: 44)
            }
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()

        _ = tester.containerView.consumeNeedsDisplay()
        #expect(!tester.containerView.needsDisplay)

        tester.sendMouseEvent(at: Point(100, 50), button: .none, phase: .changed)

        #expect(tester.containerView.needsDisplay)
    }

    @Test
    func visibleButtonRowsReuseStyledContentWhenSelectionChanges() throws {
        let driver = ButtonListSelectionDriver()

        let tester = ViewTester {
            ButtonListSelectionHost(driver: driver)
        }
        .setSize(Size(width: 180, height: 220))
        .performLayout()

        let buttonsBefore = buttonNodes(in: tester.containerView.viewTree.rootNode)
        let contentNodeIDsBefore = buttonsBefore.map { $0.contentNode.id }
        #expect(!contentNodeIDsBefore.isEmpty)

        let selection = try #require(driver.selection)
        selection.wrappedValue = 3
        tester.performLayout()

        let buttonsAfter = buttonNodes(in: tester.containerView.viewTree.rootNode)
        let contentNodeIDsAfter = buttonsAfter.map { $0.contentNode.id }

        #expect(contentNodeIDsAfter.count == contentNodeIDsBefore.count)
        #expect(contentNodeIDsAfter == contentNodeIDsBefore)
    }
}

private final class ButtonStyleStateRecorder: @unchecked Sendable {
    var states: [Button.State] = []
}

private struct RecordingButtonStyle: ButtonStyle {
    let recorder: ButtonStyleStateRecorder

    func makeBody(configuration: Configuration) -> some View {
        recorder.states.append(configuration.state)
        return configuration.label
    }
}

private final class ButtonStyleEnvironmentRecorder: @unchecked Sendable {
    var values: [Int] = []
    var states: [Button.State] = []
}

private struct EnvironmentRecordingButtonStyle: ButtonStyle {
    @Environment(\.buttonStyleCounter) private var counter

    let recorder: ButtonStyleEnvironmentRecorder

    func makeBody(configuration: Configuration) -> some View {
        recorder.values.append(counter)
        recorder.states.append(configuration.state)
        return configuration.label
            .frame(width: 100, height: 44)
    }
}

private struct ButtonStyleEnvironmentHost: View {
    @State private var counter = 0

    let recorder: ButtonStyleEnvironmentRecorder

    var body: some View {
        Button("Increment") {
            counter += 1
        }
        .buttonStyle(EnvironmentRecordingButtonStyle(recorder: recorder))
        .environment(\.buttonStyleCounter, counter)
    }
}

@MainActor
private final class ButtonListSelectionDriver {
    var selection: Binding<Int>?
}

private struct ButtonListSelectionHost: View {
    @State private var selection = 0

    let driver: ButtonListSelectionDriver
    let items = Array(0..<40)

    var body: some View {
        VStack {
            ButtonListSelectionProbe(selection: $selection, driver: driver)

            ScrollView(.vertical) {
                LazyVStack(items, id: \.self, estimatedRowHeight: 32, overscan: 2) { item in
                    Button(action: { selection = item }) {
                        Text(selection == item ? "Selected \(item)" : "Row \(item)")
                            .frame(width: 140, height: 32)
                    }
                }
            }
        }
        .frame(width: 180, height: 220)
    }
}

private struct ButtonListSelectionProbe: View {
    @Binding var selection: Int

    let driver: ButtonListSelectionDriver

    init(selection: Binding<Int>, driver: ButtonListSelectionDriver) {
        self._selection = selection
        self.driver = driver
        self.driver.selection = selection
    }

    var body: some View {
        EmptyView()
    }
}

@MainActor
private func buttonNodes(in node: ViewNode) -> [ButtonViewNode] {
    var result: [ButtonViewNode] = []

    if let button = node as? ButtonViewNode {
        result.append(button)
    }

    if let root = node as? ViewRootNode {
        result += buttonNodes(in: root.contentNode)
    } else if let modifier = node as? ViewModifierNode {
        result += buttonNodes(in: modifier.contentNode)
    } else if let container = node as? ViewContainerNode {
        for child in container.nodes {
            result += buttonNodes(in: child)
        }
    } else {
        for child in reflectedButtonChildNodes(of: node) {
            result += buttonNodes(in: child)
        }
    }

    return result
}

@MainActor
private func reflectedButtonChildNodes(of node: ViewNode) -> [ViewNode] {
    Mirror(reflecting: node).children.flatMap { child -> [ViewNode] in
        if let node = child.value as? ViewNode {
            return [node]
        }
        if let node = child.value as? ViewNode? {
            return node.map { [$0] } ?? []
        }
        return []
    }
}

private extension [UIGraphicsContext.DrawCommand] {
    var containsTextDraw: Bool {
        contains {
            if case .drawText = $0 {
                return true
            }
            if case .drawGlyph = $0 {
                return true
            }
            return false
        }
    }

    var glassConfigurations: [Glass] {
        compactMap { command in
            if case let .drawGlassRect(_, _, configuration, _) = command {
                return configuration
            }
            return nil
        }
    }

    var glassTransforms: [Transform3D] {
        compactMap { command in
            if case let .drawGlassRect(transform, _, _, _) = command {
                return transform
            }
            return nil
        }
    }
}

private func drawnGlyphMinX(in commands: [UIGraphicsContext.DrawCommand]) -> Float? {
    var minX: Float?
    for command in commands {
        guard case let .drawGlyph(glyph, transform, _) = command else {
            continue
        }
        let x = transform.w.x + glyph.position.x
        minX = minX.map { min($0, x) } ?? x
    }
    return minX
}

private func drawnGlyphMaxX(in commands: [UIGraphicsContext.DrawCommand]) -> Float? {
    var maxX: Float?
    for command in commands {
        guard case let .drawGlyph(glyph, transform, _) = command else {
            continue
        }
        let x = transform.w.x + glyph.position.z
        maxX = maxX.map { max($0, x) } ?? x
    }
    return maxX
}
