//
//  HotReloadViewTests.swift
//  AdaEngine
//
//  Created by AdaEngine on 07.05.2026.
//

import AdaUtils
import Math
import Testing
@testable import AdaPlatform
@testable import AdaUI

@MainActor
@Suite(.serialized)
struct HotReloadViewTests {
    init() async throws {
        try Application.prepareForTest()
        UIHotReloadRuntime.setFactory(nil)
    }

    @Test
    func hostUsesFallbackWhenRuntimeFactoryIsMissing() {
        let fallback = TestHotReloadUIView(name: "fallback")
        let host = UIHotReloadHostView(id: "deck") {
            fallback
        }

        #expect(host.subviews.count == 1)
        #expect(host.subviews.first === fallback)
    }

    @Test
    func reloadReplacesFallbackWithRuntimeViewForMatchingID() throws {
        let fallback = TestHotReloadUIView(name: "fallback")
        let runtimeView = TestHotReloadUIView(name: "runtime")
        let otherRuntimeView = TestHotReloadUIView(name: "other-runtime")

        let host = UIHotReloadHostView(id: "deck") {
            fallback
        }

        UIHotReloadRuntime.setFactory { id in
            id == "deck" ? runtimeView : otherRuntimeView
        }

        UIHotReloadRuntime.reload(id: "deck")

        let activeView = try #require(host.subviews.first)
        #expect(host.subviews.count == 1)
        #expect(activeView === runtimeView)
        #expect(activeView !== fallback)
    }

    @Test
    func reloadLaysOutRuntimeViewImmediately() {
        let runtimeView = LayoutTrackingHotReloadUIView(name: "runtime")
        let host = UIHotReloadHostView(id: "deck") {
            TestHotReloadUIView(name: "fallback")
        }
        host.frame = Rect(origin: .zero, size: Size(width: 320, height: 240))
        _ = host.consumeNeedsDisplay()

        UIHotReloadRuntime.setFactory { id in
            id == "deck" ? runtimeView : nil
        }

        UIHotReloadRuntime.reload(id: "deck")

        #expect(runtimeView.frame.size == Size(width: 320, height: 240))
        #expect(runtimeView.bounds.size == Size(width: 320, height: 240))
        #expect(runtimeView.layoutSubviewsCallCount > 0)
        #expect(host.consumeNeedsDisplay())
    }

    @Test
    func reloadSeedsRuntimeContainerWithHostEnvironment() throws {
        let host = UIHotReloadHostView(id: "deck") {
            TestHotReloadUIView(name: "fallback")
        }
        host.safeAreaInsets = EdgeInsets(top: 12, leading: 8, bottom: 4, trailing: 2)
        host.colorScheme = .dark

        UIHotReloadRuntime.setFactory { id in
            guard id == "deck" else {
                return nil
            }

            return UIContainerView(rootView: EmptyView())
        }

        UIHotReloadRuntime.reload(id: "deck")

        let container = try #require(host.subviews.first as? UIContainerView<EmptyView>)
        #expect(container.viewTree.rootNode.environment.safeAreaInsets == host.safeAreaInsets)
        #expect(container.viewTree.rootNode.environment.colorScheme == .dark)
    }

    @Test
    func containerUsesInitialHostScaleEnvironment() {
        var environment = EnvironmentValues()
        environment.scaleFactor = 2.5

        let container = UIHotReloadRuntime.withInitialHostEnvironment(environment) {
            UIContainerView(rootView: EmptyView())
        }

        #expect(container.viewTree.rootNode.environment.scaleFactor == 2.5)
    }

    @Test
    func reloadOnlyAffectsMatchingID() throws {
        let deckRuntimeView = TestHotReloadUIView(name: "deck-runtime")
        let panelRuntimeView = TestHotReloadUIView(name: "panel-runtime")
        let deckHost = UIHotReloadHostView(id: "deck") {
            TestHotReloadUIView(name: "deck-fallback")
        }
        let panelHost = UIHotReloadHostView(id: "panel") {
            TestHotReloadUIView(name: "panel-fallback")
        }
        let panelFallback = try #require(panelHost.subviews.first)

        UIHotReloadRuntime.setFactory { id in
            id == "deck" ? deckRuntimeView : panelRuntimeView
        }

        UIHotReloadRuntime.reload(id: "deck")

        #expect(deckHost.subviews.first === deckRuntimeView)
        #expect(panelHost.subviews.first === panelFallback)
    }

    @Test
    func reloadAllAffectsAutomaticallyIdentifiedHost() throws {
        let automaticID = UIHotReloadRuntime.automaticID(
            fileID: "Deck.swift",
            function: "body",
            line: 42,
            column: 9
        )
        let fallback = TestHotReloadUIView(name: "fallback")
        let runtimeView = TestHotReloadUIView(name: "runtime")
        let host = UIHotReloadHostView(id: automaticID) {
            fallback
        }

        UIHotReloadRuntime.setFactory { id in
            id == automaticID ? runtimeView : nil
        }

        UIHotReloadRuntime.reloadAll()

        let activeView = try #require(host.subviews.first)
        #expect(host.subviews.count == 1)
        #expect(activeView === runtimeView)
        #expect(activeView !== fallback)
    }

    @Test
    func hotReloadModifierBuildsAsRegularAdaUIView() {
        let tester = ViewTester {
            EmptyView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .hotReload(id: "modifier")
        }
        .setSize(Size(width: 320, height: 240))
        .performLayout()

        #expect(tester.containerView.viewTree.rootNode.frame.size == Size(width: 320, height: 240))
    }

    @Test
    func hotReloadingModifierBuildsAsRegularAdaUIView() {
        let tester = ViewTester {
            EmptyView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .hotReloading()
        }
        .setSize(Size(width: 320, height: 240))
        .performLayout()

        #expect(tester.containerView.viewTree.rootNode.frame.size == Size(width: 320, height: 240))
    }

    @Test
    func automaticHotReloadIDIsStableForSourceLocation() {
        let first = UIHotReloadRuntime.automaticID(
            fileID: "Deck.swift",
            function: "body",
            line: 42,
            column: 9
        )
        let second = UIHotReloadRuntime.automaticID(
            fileID: "Deck.swift",
            function: "body",
            line: 42,
            column: 9
        )

        #expect(first == second)
    }

    @Test
    func uiViewRepresentableReceivesPlacedFrame() {
        let view = TestHotReloadUIView(name: "represented")

        _ = ViewTester {
            TestUIViewRepresentable(view: view)
        }
        .setSize(Size(width: 320, height: 240))
        .performLayout()

        #expect(view.frame.size == Size(width: 320, height: 240))
        #expect(view.bounds.size == Size(width: 320, height: 240))
    }
}

@MainActor
private final class LayoutTrackingHotReloadUIView: TestHotReloadUIView {
    var layoutSubviewsCallCount = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutSubviewsCallCount += 1
    }
}

@MainActor
private class TestHotReloadUIView: UIView {
    let name: String

    init(name: String) {
        self.name = name
        super.init()
        self.backgroundColor = .clear
    }

    required init(frame: Rect) {
        self.name = "frame"
        super.init(frame: frame)
        self.backgroundColor = .clear
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        proposal.replacingUnspecifiedDimensions(by: Size(width: 10, height: 10))
    }
}

@MainActor
private struct TestUIViewRepresentable: UIViewRepresentable {
    let view: TestHotReloadUIView

    func makeUIView(in context: Context) -> TestHotReloadUIView {
        view
    }

    func updateUIView(_ view: TestHotReloadUIView, in context: Context) {}
}
