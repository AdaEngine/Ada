import AdaAnimation
import AdaInput
@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
struct PresentationTransitionTests {
    init() async throws { try Application.prepareForTest() }

    @Test
    func navigationPushPopRetainsScreensAndReversesDirection() throws {
        let model = TransitionModel()
        let tester = ViewTester {
            NavigationStack(path: model.pathBinding) {
                Color.red.accessibilityIdentifier("root")
                    .navigate(for: String.self) { _ in Color.blue.accessibilityIdentifier("detail") }
            }
            .navigationBarHidden()
            .accessibilityIdentifier("stack")
        }.setSize(Size(width: 300, height: 200)).performLayout()
        let stack = try #require(tester.findNodeByAccessibilityIdentifier("stack") as? NavigationStackNode)
        let root = stack.presentation.selected
        model.path.append("detail")
        tester.invalidateContent().performLayout()
        #expect(stack.presentation.nodes.count == 2)
        #expect(stack.presentation.entries.last?.pose.x == 1)
        tester.advanceFrame(deltaTime: 0.14)
        #expect(abs((stack.presentation.entries.last?.pose.x ?? 0) - 0.5) < 0.02)
        tester.advanceFrame(deltaTime: 0.14)
        #expect(stack.presentation.nodes.count == 1)
        #expect(!stack.presentation.isAnimating)

        model.path.removeLast()
        tester.invalidateContent().performLayout()
        #expect(stack.presentation.selected === root)
        #expect(stack.presentation.nodes.count == 2)
        tester.advanceFrame(deltaTime: 0.14)
        #expect((stack.presentation.entries.last?.pose.x ?? 0) > 0)
        tester.advanceFrame(deltaTime: 0.14)
        #expect(stack.presentation.nodes.count == 1)
        #expect(stack.presentation.selected === root)
    }

    @Test
    func tabsFadeAndScaleAndRapidReturnKeepsPresentationContinuous() throws {
        let model = TransitionModel()
        let tester = ViewTester {
            TabView(selection: model.tabBinding) {
                Tab("First", value: 0) { Color.red.accessibilityIdentifier("first") }
                Tab("Second", value: 1) { Color.blue.accessibilityIdentifier("second") }
            }
        }.setSize(Size(width: 300, height: 200)).performLayout()
        let first = try #require(tester.findNodeByAccessibilityIdentifier("first"))
        let proxy = try #require(ancestor(of: first, type: TabContentProxyNode.self))
        model.tab = 1
        tester.invalidateContent().performLayout()
        #expect(proxy.presentation.nodes.count == 2)
        #expect(proxy.presentation.entries.last?.pose.opacity == 0)
        #expect(proxy.presentation.entries.last?.pose.scale == 0.96)
        tester.advanceFrame(deltaTime: 0.14)
        let firstPose = try #require(proxy.presentation.entries.first { $0.node === first }?.pose)
        #expect(firstPose.opacity > 0 && firstPose.opacity < 1)
        model.tab = 0
        tester.invalidateContent().performLayout()
        let reversed = try #require(proxy.presentation.entries.first { $0.node === first }?.pose)
        #expect(reversed.opacity == firstPose.opacity)
        #expect(reversed.scale == firstPose.scale)
        tester.advanceFrame(deltaTime: 0.3)
        #expect(proxy.presentation.nodes.count == 1)
        #expect(proxy.presentation.selected === first)
        #expect(proxy.presentation.entries.first?.pose.opacity == 1)
    }

    @Test(arguments: [false, true])
    func modalRetainsOutgoingContentAndBlocksUnderlyingInput(sheet: Bool) throws {
        let model = TransitionModel()
        let tester = ViewTester {
            modalHost(model: model, sheet: sheet)
        }.setSize(Size(width: 400, height: 300)).performLayout()
        let host = try #require(tester.findNodeByAccessibilityIdentifier("modal-host") as? FullScreenCoverNode)
        model.show = true
        tester.advanceFrame(deltaTime: 0)
        #expect(host.presentation.isAnimating)
        #expect(host.presentation.nodes.count == 1)
        let retained = host.presentation.selected
        tester.advanceFrame(deltaTime: 0.14)
        if sheet {
            #expect((host.presentation.entries.first?.pose.opacity ?? 0) > 0)
            #expect((host.presentation.entries.first?.pose.scale ?? 1) < 1)
        } else {
            #expect(abs((host.presentation.entries.first?.pose.y ?? 0) - 0.5) < 0.02)
        }
        tester.advanceFrame(deltaTime: 0.14)
        model.show = false
        tester.advanceFrame(deltaTime: 0)
        #expect(host.presentation.selected == nil)
        #expect(host.presentation.nodes.first === retained)
        #expect(tester.click(at: Point(10, 10)) === host)
        tester.advanceFrame(deltaTime: 0.3)
        #expect(host.presentation.nodes.isEmpty)
        #expect(retained?.parent == nil)
    }

    @Test(arguments: [false, true])
    func opacityCoverDoesNotMaskSafeAreaBackground(presented: Bool) throws {
        let model = TransitionModel()
        let tester = ViewTester {
            Color.red.fullScreenCover(isPresented: model.showBinding, transition: .opacity) {
                Color.black.ignoresSafeArea()
            }.accessibilityIdentifier("hidden-opacity-modal")
        }.setSize(Size(width: 400, height: 300)).performLayout()
        let host = try #require(tester.findNodeByAccessibilityIdentifier("hidden-opacity-modal") as? FullScreenCoverNode)
        model.show = presented
        tester.advanceFrame(deltaTime: 0.3)
        let context = UIGraphicsContext()
        host.draw(with: context)
        #expect(!context.getDrawCommands().isEmpty)
        #expect(!context.getDrawCommands().contains { command in
            if case .pushClipPath = command {
                return true
            }
            return false
        })
    }

    @Test
    func opacityCoverFadesInPlaceAndRetainsInputBarrierUntilDismissed() throws {
        let model = TransitionModel()
        let tester = ViewTester {
            Color.red.fullScreenCover(isPresented: model.showBinding, transition: .opacity) {
                Color.black.ignoresSafeArea()
            }.accessibilityIdentifier("opacity-modal")
        }.setSize(Size(width: 400, height: 300)).performLayout()
        let host = try #require(tester.findNodeByAccessibilityIdentifier("opacity-modal") as? FullScreenCoverNode)
        model.show = true
        tester.advanceFrame(deltaTime: 0)
        let entry = try #require(host.presentation.entries.first)
        #expect(entry.pose.opacity == 0)
        #expect(entry.pose.x == 0 && entry.pose.y == 0 && entry.pose.scale == 1)
        tester.advanceFrame(deltaTime: 0.14)
        #expect(entry.pose.opacity > 0 && entry.pose.opacity < 1)
        #expect(entry.pose.y == 0 && entry.pose.scale == 1)
        tester.advanceFrame(deltaTime: 0.14)
        #expect(entry.pose.opacity == 1)
        model.show = false
        tester.advanceFrame(deltaTime: 0.14)
        #expect(entry.pose.opacity > 0 && entry.pose.opacity < 1)
        #expect(entry.pose.y == 0 && entry.pose.scale == 1)
        #expect(tester.click(at: Point(10, 10)) === host)
        tester.advanceFrame(deltaTime: 0.3)
        #expect(host.presentation.nodes.isEmpty)
    }

    @Test
    func explicitNilTransactionDisablesNavigationTransition() throws {
        let model = TransitionModel()
        let tester = ViewTester {
            NavigationStack(path: model.pathBinding) {
                Color.red.navigate(for: String.self) { _ in Color.blue }
            }.accessibilityIdentifier("stack")
        }.setSize(Size(width: 300, height: 200)).performLayout()
        let stack = try #require(tester.findNodeByAccessibilityIdentifier("stack") as? NavigationStackNode)
        withAnimation(nil) {
            model.path.append("detail")
            tester.invalidateContent().performLayout()
        }
        #expect(!stack.presentation.isAnimating)
        #expect(stack.presentation.nodes.count == 1)
    }

    @Test
    func internallyOwnedPathSurvivesParentRebuild() throws {
        let tester = ViewTester {
            NavigationStack {
                Text("Root").navigate(for: String.self) { Text($0) }
            }.accessibilityIdentifier("internal-stack")
        }.setSize(Size(width: 400, height: 300)).performLayout()
        let stack = try #require(tester.findNodeByAccessibilityIdentifier("internal-stack") as? NavigationStackNode)
        stack.navigationContext.push("Detail")
        tester.advanceFrame(deltaTime: 0.3)
        let detail = stack.presentation.selected
        tester.invalidateContent().performLayout().advanceFrame(deltaTime: 0.3)
        #expect(stack.navigationContext.path.count == 1)
        #expect(stack.presentation.selected === detail)
    }

    @Test
    func paddedTabNavigationKeepsItsLayoutBoundsDuringPushAndPop() throws {
        let model = TransitionModel()
        let tester = ViewTester {
            VStack(spacing: 16) {
                Text("Header")
                TabView(selection: model.tabBinding) {
                    Tab("Navigation", value: 0) {
                        NavigationStack(path: model.pathBinding) {
                            Color.red.navigate(for: String.self) { _ in Color.blue }
                        }.accessibilityIdentifier("padded-stack")
                    }
                    Tab("Other", value: 1) { Color.green }
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.setSize(Size(width: 800, height: 600)).performLayout()
        let stack = try #require(tester.findNodeByAccessibilityIdentifier("padded-stack"))
        let initial = stack.absoluteFrame()
        #expect(initial.minX >= 24)
        #expect(initial.maxX <= 776)
        withAnimation(.linear(duration: 1)) {
            model.path.append("detail")
            tester.invalidateContent()
        }
        tester.advanceFrame(deltaTime: 0)
        tester.advanceFrame(deltaTime: 0.5)
        #expect(stack.absoluteFrame() == initial)
        tester.advanceFrame(deltaTime: 0.5)
        #expect(stack.absoluteFrame() == initial)
        withAnimation(.linear(duration: 1)) {
            model.path.removeLast()
            tester.invalidateContent()
        }
        tester.advanceFrame(deltaTime: 1)
        #expect(stack.absoluteFrame() == initial)
    }

    @Test
    func outgoingGlyphsAreCommittedBeforeIncomingOpaqueBackground() throws {
        let model = TransitionModel()
        let tester = ViewTester {
            NavigationStack(path: model.pathBinding) {
                Text("Outgoing text").navigate(for: String.self) { _ in Color.blue }
            }.navigationBarHidden().accessibilityIdentifier("paint-stack")
        }.setSize(Size(width: 400, height: 300)).performLayout()
        let stack = try #require(tester.findNodeByAccessibilityIdentifier("paint-stack") as? NavigationStackNode)
        model.path.append("Detail")
        tester.invalidateContent().performLayout().advanceFrame(deltaTime: 0.14)
        let context = UIGraphicsContext()
        stack.draw(with: context)
        let commands = context.getDrawCommands()
        let textIndex = try #require(commands.firstIndex {
            switch $0 {
            case .drawText, .drawGlyph: true
            default: false
            }
        })
        let backgroundIndex = try #require(commands.lastIndex {
            if case let .drawQuad(_, _, color) = $0 {
                return color == .blue
            }
            return false
        })
        #expect(textIndex < backgroundIndex)
        #expect(commands[(textIndex + 1)..<backgroundIndex].contains {
            if case .commit = $0 {
                return true
            }
            return false
        })
    }

    @Test
    func navigationInsideCachedTabRemountsItsVisibleScreen() throws {
        let model = TransitionModel()
        let tester = ViewTester {
            TabView(selection: model.tabBinding) {
                Tab("First", value: 0) {
                    NavigationStack(path: model.pathBinding) {
                        Color.red.navigate(for: String.self) { _ in Color.blue.accessibilityIdentifier("detail") }
                    }.accessibilityIdentifier("nested-stack")
                }
                Tab("Second", value: 1) { Color.green }
            }
        }.setSize(Size(width: 400, height: 300)).performLayout()
        let stack = try #require(tester.findNodeByAccessibilityIdentifier("nested-stack") as? NavigationStackNode)
        model.path.append("detail")
        tester.invalidateContent().performLayout().advanceFrame(deltaTime: 0.3)
        let detail = stack.presentation.selected
        model.tab = 1
        tester.invalidateContent().performLayout().advanceFrame(deltaTime: 0.3)
        model.tab = 0
        tester.invalidateContent().performLayout().advanceFrame(deltaTime: 0.3)
        #expect(stack.presentation.selected === detail)
        #expect(stack.presentation.nodes.count == 1)
        #expect(stack.presentation.selected?.parent === stack)
    }

    @Test
    func dismissThenReopenReusesThePresentedNode() throws {
        let model = TransitionModel()
        let tester = ViewTester { modalHost(model: model, sheet: true) }
            .setSize(Size(width: 400, height: 300)).performLayout()
        let host = try #require(tester.findNodeByAccessibilityIdentifier("modal-host") as? FullScreenCoverNode)
        model.show = true
        tester.advanceFrame(deltaTime: 0.3)
        let initial = host.presentation.selected
        model.show = false
        tester.advanceFrame(deltaTime: 0.14)
        let opacity = host.presentation.entries.first?.pose.opacity
        model.show = true
        tester.advanceFrame(deltaTime: 0)
        #expect(host.presentation.selected === initial)
        #expect(host.presentation.entries.first?.pose.opacity == opacity)
        tester.advanceFrame(deltaTime: 0.3)
        #expect(host.presentation.nodes.count == 1)
    }

    @Test
    func modalBackdropDoesNotForwardClicksToUnderlyingButton() {
        let model = TransitionModel()
        var clicks = 0
        let tester = ViewTester {
            Button(action: { clicks += 1 }) { Color.red.frame(width: 400, height: 300) }
                .sheet(isPresented: model.showBinding) { Color.blue.frame(width: 100, height: 100) }
        }.setSize(Size(width: 400, height: 300)).performLayout()
        model.show = true
        tester.advanceFrame(deltaTime: 0.3)
        tester.sendMouseEvent(at: Point(10, 10), phase: .began)
        tester.sendMouseEvent(at: Point(10, 10), phase: .ended)
        #expect(clicks == 0)
        model.show = false
        tester.advanceFrame(deltaTime: 0)
        tester.sendMouseEvent(at: Point(10, 10), phase: .began)
        tester.sendMouseEvent(at: Point(10, 10), phase: .ended)
        #expect(clicks == 0)
        tester.advanceFrame(deltaTime: 0.3)
        tester.sendMouseEvent(at: Point(10, 10), phase: .began)
        tester.sendMouseEvent(at: Point(10, 10), phase: .ended)
        #expect(clicks == 1)
    }

    @Test
    func showingAModalClearsUnderlyingKeyboardFocus() throws {
        let model = TransitionModel()
        let tester = ViewTester {
            TextField("Name", text: .constant("Ada"))
                .accessibilityIdentifier("underlying-field")
                .sheet(isPresented: model.showBinding) { Color.blue.frame(width: 100, height: 100) }
        }.setSize(Size(width: 400, height: 300)).performLayout()
        let field = try #require(tester.findNodeByAccessibilityIdentifier("underlying-field"))
        tester.containerView.focusManager.focus(field)
        model.show = true
        tester.advanceFrame(deltaTime: 0)
        #expect(tester.containerView.focusManager.focusedNode == nil)
    }

    @Test
    func modalBlocksUnderlyingKeyboardShortcutsUntilDismissalCompletes() {
        let model = TransitionModel()
        var count = 0
        let tester = ViewTester {
            Button("Behind") { count += 1 }
                .keyboardShortcut("p", modifiers: [])
                .sheet(isPresented: model.showBinding) { Color.blue.frame(width: 100, height: 100) }
        }.setSize(Size(width: 400, height: 300)).performLayout()
        tester.sendKeyEvent(.p)
        #expect(count == 1)
        model.show = true
        tester.advanceFrame(deltaTime: 0.3)
        tester.sendKeyEvent(.p)
        #expect(count == 1)
        model.show = false
        tester.advanceFrame(deltaTime: 0)
        tester.sendKeyEvent(.p)
        #expect(count == 1)
        tester.advanceFrame(deltaTime: 0.3)
        tester.sendKeyEvent(.p)
        #expect(count == 2)
    }

    @ViewBuilder
    private func modalHost(model: TransitionModel, sheet: Bool) -> some View {
        if sheet {
            Color.red.sheet(isPresented: model.showBinding) {
                Color.blue.frame(width: 200, height: 120).accessibilityIdentifier("modal")
            }.accessibilityIdentifier("modal-host")
        } else {
            Color.red.fullScreenCover(isPresented: model.showBinding) {
                Color.blue.accessibilityIdentifier("modal")
            }.accessibilityIdentifier("modal-host")
        }
    }

    private func ancestor<Node: ViewNode>(of node: ViewNode, type: Node.Type) -> Node? {
        var current: ViewNode? = node
        while let value = current {
            if let found = value as? Node {
                return found
            }
            current = value.parent
        }
        return nil
    }
}

@MainActor
private final class TransitionModel {
    var path = NavigationPath()
    var tab = 0
    var show = false
    var pathBinding: Binding<NavigationPath> { Binding(get: { self.path }, set: { self.path = $0 }) }
    var tabBinding: Binding<Int> { Binding(get: { self.tab }, set: { self.tab = $0 }) }
    var showBinding: Binding<Bool> { Binding(get: { self.show }, set: { self.show = $0 }) }
}
