import AdaInput
@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
struct NavigationInteractivePopTests {
    init() async throws { try Application.prepareForTest() }

    @Test
    func dragTracksBothScreensAndReversesWithoutChangingPath() throws {
        let host = try Host()
        let detail = host.stack.presentation.selected
        host.touch(12, .began)
        host.touch(112, .moved)
        #expect(host.model.path.count == 1)
        #expect(host.stack.presentation.selected === detail)
        #expect(host.stack.presentation.isInteractive)
        #expect(!host.stack.presentation.isAnimating)
        #expect(host.stack.presentation.nodes.count == 2)
        #expect(host.stack.presentation.entries.last?.pose.x == 0.25)
        #expect(host.stack.presentation.entries.first?.pose.x == -0.1875)
        host.tester.advanceFrame(deltaTime: 1)
        #expect(host.stack.presentation.entries.last?.pose.x == 0.25)
        host.touch(52, .moved)
        #expect(host.stack.presentation.entries.last?.pose.x == 0.1)
        host.touch(-20, .moved)
        #expect(host.stack.presentation.entries.last?.pose.x == 0)
    }

    @Test(arguments: [TouchEvent.Phase.ended, .cancelled])
    func shortOrCancelledDragSettlesBackToSameScreen(phase: TouchEvent.Phase) throws {
        let host = try Host()
        let detail = host.stack.presentation.selected
        host.touch(12, .began)
        host.touch(52, .moved)
        host.touch(52, phase)
        #expect(host.model.path.count == 1)
        #expect(host.stack.presentation.selected === detail)
        #expect(!host.stack.presentation.isInteractive)
        #expect(host.stack.presentation.isAnimating)
        #expect(host.stack.presentation.entries.last?.pose.x == 0.1)
        host.tester.advanceFrame(deltaTime: 0.3)
        #expect(host.stack.presentation.nodes.count == 1)
        #expect(host.stack.presentation.selected === detail)
        #expect(host.stack.presentation.entries.first?.pose.x == 0)
        host.touch(12, .began, contact: RID())
        #expect(host.tester.click(at: Point(20, 200)) === host.stack)
    }

    @Test
    func completingPopContinuesFromReleasePoseAndPopsExactlyOnce() async throws {
        let host = try Host(depth: 2)
        host.touch(12, .began)
        host.touch(212, .moved)
        let previous = host.stack.presentation.nodes.first
        host.touch(212, .ended)
        #expect(host.model.path.count == 2)
        #expect(host.stack.presentation.selected === previous)
        #expect(host.stack.presentation.entries.last?.pose.x == 0.5)
        #expect(host.stack.presentation.isAnimating)
        host.tester.advanceFrame(deltaTime: 0.07)
        #expect((host.stack.presentation.entries.last?.pose.x ?? 0) > 0.5)
        for _ in 0..<50 where host.model.path.count == 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(host.model.path.count == 1)
        #expect(host.stack.presentation.selected === previous)
        host.tester.advanceFrame(deltaTime: 0.3)
        #expect(host.stack.presentation.nodes.count == 1)
        #expect(host.stack.presentation.selected === previous)
    }

    @Test
    func verticalDriftCancelsAndAnotherFingerCannotFinishThePop() throws {
        let host = try Host()
        host.touch(12, .began)
        host.touch(112, .moved)
        host.touch(212, .ended, contact: RID())
        #expect(host.stack.presentation.isInteractive)
        host.touch(212, .moved, y: 290)
        #expect(!host.stack.presentation.isInteractive)
        host.touch(212, .ended, y: 290)
        host.tester.advanceFrame(deltaTime: 0.3)
        #expect(host.model.path.count == 1)
        #expect(host.stack.presentation.nodes.count == 1)
    }

    @Test
    func parentRebuildKeepsTheDragAndExternalPathChangeCancelsIt() throws {
        let host = try Host()
        host.touch(12, .began)
        host.touch(112, .moved)
        host.tester.invalidateContent().performLayout()
        #expect(host.stack.presentation.isInteractive)
        #expect(host.stack.presentation.entries.last?.pose.x == 0.25)
        host.model.path.append("replacement")
        host.tester.invalidateContent().performLayout().advanceFrame(deltaTime: 0.3)
        #expect(!host.stack.presentation.isInteractive)
        #expect(host.stack.navigationContext.path.count == 2)
        #expect(host.stack.presentation.nodes.count == 1)
    }

    @Test
    func deferredCommitCannotOverwriteAnExternalPathChange() async throws {
        let host = try Host()
        host.touch(12, .began)
        host.touch(212, .moved)
        host.touch(212, .ended)
        host.model.path.append("replacement")
        await Task.yield()
        try await Task.sleep(for: .milliseconds(120))
        #expect(host.model.path.count == 2)
        #expect(host.stack.navigationContext.path.count == 2)
    }

    @Test
    func disabledAnimationsKeepOutgoingScreenMountedUntilTouchDispatchCompletes() async throws {
        let host = try Host(disablesAnimations: true)
        let detail = host.stack.presentation.selected
        host.touch(12, .began)
        host.touch(212, .moved)
        host.touch(212, .ended)
        #expect(detail?.parent === host.stack)
        #expect(host.model.path.count == 1)
        for _ in 0..<50 where !host.model.path.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(host.model.path.isEmpty)
        #expect(detail?.parent == nil)
        #expect(!host.stack.presentation.isAnimating)
        #expect(host.stack.presentation.nodes.count == 1)
    }

    @Test
    func revealedScreenAndOutgoingScreenDoNotReceiveInputDuringDrag() throws {
        let host = try Host()
        host.touch(12, .began)
        host.touch(212, .moved)
        #expect(host.stack.inputContentNodes.isEmpty)
        #expect(host.stack.presentation.nodes.allSatisfy { !$0.acceptsPresentationInput })
        #expect(host.tester.click(at: Point(40, 200)) === host.stack)
        #expect(host.tester.click(at: Point(300, 200)) === host.stack)
        host.touch(212, .cancelled)
        host.tester.advanceFrame(deltaTime: 0.3)
        #expect(!host.stack.inputContentNodes.isEmpty)
        #expect(host.stack.presentation.selected?.acceptsPresentationInput == true)
    }

    @Test(arguments: [0, 1])
    func rootAndHiddenBackButtonDoNotBeginInteractivePop(depth: Int) throws {
        let host = try Host(depth: depth, hidesBackButton: true)
        host.touch(12, .began)
        host.touch(212, .moved)
        host.touch(212, .ended)
        #expect(!host.stack.presentation.isInteractive)
        #expect(host.model.path.count == depth)
        #expect(host.stack.presentation.nodes.count == 1)
    }

    @Test(arguments: [false, true])
    func revealedScreenKeepsItsOwnNavigationBarLayout(rootScrolls: Bool) throws {
        let model = Model()
        let tester = ViewTester {
            NavigationStack(path: Binding(get: { model.path }, set: { model.path = $0 })) {
                screen(scrolls: rootScrolls).navigationTitle("Root")
                    .navigate(for: String.self) { _ in
                        screen(scrolls: !rootScrolls).navigationTitle("Detail")
                    }
            }.accessibilityIdentifier("stack")
        }.setSize(Size(width: 400, height: 400)).performLayout()
        let stack = try #require(tester.findNodeByAccessibilityIdentifier("stack") as? NavigationStackNode)
        let root = try #require(stack.presentation.selected)
        let rootFrame = root.frame
        model.path.append("detail")
        tester.invalidateContent().performLayout().advanceFrame(deltaTime: 0.3)
        let detail = try #require(stack.presentation.selected)
        let detailFrame = detail.frame
        let contact = RID()
        for (x, phase): (Float, TouchEvent.Phase) in [(12, .began), (212, .moved)] {
            tester.containerView.onTouchesEvent([
                TouchEvent(window: contact, location: Point(x, 200), phase: phase, time: 0, contactID: contact)
            ])
        }
        #expect(stack.presentation.isInteractive)
        #expect(stack.presentation.nodes.first === root)
        #expect(root.frame == rootFrame)
        #expect(detail.frame == detailFrame)
        if rootScrolls { #expect(root.environment.safeAreaInsets.top == 92) }
    }

    @ViewBuilder
    private func screen(scrolls: Bool) -> some View {
        if scrolls {
            ScrollView { Color.red.frame(height: 600) }
        } else {
            Color.blue
        }
    }

    private final class Model {
        var path = NavigationPath()
    }

    @MainActor
    private struct Host {
        let model: Model
        let tester: ViewTester<AnyView>
        let stack: NavigationStackNode
        let contact = RID()
        let window = RID()

        init(depth: Int = 1, hidesBackButton: Bool = false, disablesAnimations: Bool = false) throws {
            let model = Model()
            for index in 0..<depth { model.path.append("Detail \(index)") }
            self.model = model
            tester = ViewTester(rootView: AnyView(
                NavigationStack(path: Binding(get: { model.path }, set: { model.path = $0 })) {
                    Color.red.navigate(for: String.self) { _ in
                        Color.blue.navigationBarBackButtonHidden(hidesBackButton)
                    }
                }
                .navigationBarHidden()
                .environment(\.animationsDisabled, disablesAnimations)
                .accessibilityIdentifier("stack")
            )).setSize(Size(width: 400, height: 400)).performLayout()
            stack = try #require(tester.findNodeByAccessibilityIdentifier("stack") as? NavigationStackNode)
        }

        func touch(_ x: Float, _ phase: TouchEvent.Phase, y: Float = 200, contact: RID? = nil) {
            tester.containerView.onTouchesEvent([
                TouchEvent(window: window, location: Point(x, y), phase: phase, time: 0, contactID: contact ?? self.contact)
            ])
        }
    }
}
