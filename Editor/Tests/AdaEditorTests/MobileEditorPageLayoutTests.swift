@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite("Mobile page navigation insets", .serialized)
struct MobileEditorPageLayoutTests {
    @Test("Animated pushes and pops retain the initial navigation clearance")
    func animatedNavigation() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "MobilePageLayoutTests")))
        }
        let container = UIContainerView(rootView: MobilePageNavigationFixture())
        container.frame = Rect(x: 0, y: 0, width: 400, height: 800)
        container.bounds.size = container.frame.size
        container.safeAreaInsets = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        container.layoutIfNeeded()
        // Observed page reconstruction can supply a child snapshot before navigation insets are reapplied.
        let scroll = try #require(container.viewTree.rootNode.findNodyByAccessibilityIdentifier("AdaEditor.Mobile.PageScroll") as? ScrollViewNode)
        var childEnvironment = scroll.environment
        childEnvironment.navigationBarContentInset = 0
        scroll.updateEnvironment(childEnvironment)
        scroll.performLayout()
        let initial = try container.uiNode(matching: .accessibilityIdentifier("MobilePage.FirstContent"))
        #expect(abs(initial.absoluteFrame.minY - 178) < 1)
        for _ in 0..<3 {
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("MobilePage.Push"))
            for _ in 0..<40 {
                container.update(1 / 60)
                container.layoutIfNeeded()
                await Task.yield()
            }
            let first = try container.uiNode(matching: .accessibilityIdentifier("MobilePage.FirstContent"))
            #expect(abs(first.absoluteFrame.minY - 178) < 1)
        }
        for _ in 0..<3 {
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("MobilePage.Pop"))
            for _ in 0..<40 {
                container.update(1 / 60)
                container.layoutIfNeeded()
                await Task.yield()
            }
            let first = try container.uiNode(matching: .accessibilityIdentifier("MobilePage.FirstContent"))
            #expect(abs(first.absoluteFrame.minY - 178) < 1)
        }
    }

    @Test("Device safe area is counted once on root and pushed pages", arguments: [Float(0), 62, 72], [false, true])
    func topInset(_ top: Float, _ pushed: Bool) throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "MobilePageLayoutTests")))
        }
        var path = NavigationPath()
        if pushed { path.append("Agent") }
        let container = UIContainerView(rootView: NavigationStack(path: .constant(path)) {
            page("Root")
                .navigate(for: String.self) { title in page(title) }
        })
        container.frame = Rect(x: 0, y: 0, width: 400, height: 800)
        container.bounds.size = container.frame.size
        container.safeAreaInsets = EdgeInsets(top: top, leading: 0, bottom: 34, trailing: 0)
        container.layoutIfNeeded()
        let first = try container.uiNode(matching: .accessibilityIdentifier("MobilePage.FirstContent"))
        // One host safe-area inset, one 92-point navigation bar, and the page's 24-point padding.
        #expect(abs(first.absoluteFrame.minY - (top + 116)) < 1)
        let scroll = try #require(container.viewTree.rootNode.findNodyByAccessibilityIdentifier("AdaEditor.Mobile.PageScroll") as? ScrollViewNode)
        #expect(abs(scroll.absoluteFrame().minY - top) < 1)
        #expect(scroll.frame.height == 800 - top - 34)
        #expect(scroll.scrollToVisibleRect(Rect(x: 0, y: 780, width: 1, height: 20), in: scroll))
        #expect(scroll.contentOffset.y > 0)
        let content = try #require(container.viewTree.rootNode.findNodyByAccessibilityIdentifier("MobilePage.FirstContent"))
        #expect(content.calculateVisibleFrame().minY < top + 92)
    }

    private func page(_ title: String, height: Float = 700) -> some View {
        MobileEditorPageScrollView {
            Color.clear.frame(height: height)
                .accessibilityIdentifier("MobilePage.FirstContent")
                .padding(.top, 24)
        }
        .navigationTitle(title)
    }
}

private struct MobilePageNavigationFixture: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            MobilePageContentFixture(title: "Root", push: { path.append("Settings") }, pop: { path.removeLast() })
                .navigate(for: String.self) { title in
                    MobilePageContentFixture(title: title, push: { path.append("Settings") }, pop: { path.removeLast() })
                }
        }
        .foregroundColor(colorScheme == .dark ? .white : .black)
    }
}

private struct MobilePageContentFixture: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let push: () -> Void
    let pop: () -> Void

    var body: some View {
        MobileEditorPageScrollView {
            VStack {
                Color.clear.frame(height: 240)
                .accessibilityIdentifier("MobilePage.FirstContent")
                Button("Push", action: push).accessibilityIdentifier("MobilePage.Push")
                Button("Pop", action: pop).accessibilityIdentifier("MobilePage.Pop")
            }
                .padding(.top, 24)
        }
        .foregroundColor(colorScheme == .dark ? .white : .black)
        .navigationTitle(title)
    }
}
