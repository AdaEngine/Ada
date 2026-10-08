import Testing
@testable import AdaEngine

@MainActor
struct AdaUIDebug3DTests {
    @Test
    func projectionPreservesDepthAndScaledFrames() {
        let root = makeNode(
            runtimeId: "root",
            viewType: "RootView",
            frame: Rect(x: 0, y: 0, width: 200, height: 100),
            children: [
                makeNode(
                    runtimeId: "child",
                    viewType: "ChildView",
                    frame: Rect(x: 20, y: 10, width: 40, height: 30)
                )
            ]
        )
        let window = AdaUIDebug3DWindowSnapshot(
            id: RID(),
            title: "Test",
            frame: Rect(x: 0, y: 0, width: 320, height: 240),
            roots: [root]
        )

        let items = AdaUIDebug3DLayout.project(
            windows: [window],
            projection: AdaUIDebug3DProjection(
                zoom: 0.5,
                layerSpacing: 20,
                pan: Point(10, 30),
                viewportSize: Size(width: 500, height: 400),
                depthLimit: 10
            )
        )

        #expect(items.count == 2)
        #expect(items[0].runtimeId == "root")
        #expect(items[0].depth == 0)
        #expect(items[0].rect.size == Size(width: 100, height: 50))
        #expect(items[1].runtimeId == "child")
        #expect(items[1].depth == 1)
        #expect(items[1].rect.size == Size(width: 20, height: 15))
        #expect(items[1].rect.origin.x > items[0].rect.origin.x)
    }

    @Test
    func projectionSkipsZeroSizedNodesButKeepsChildren() {
        let root = makeNode(
            runtimeId: "root",
            viewType: "RootView",
            frame: Rect(x: 0, y: 0, width: 0, height: 0),
            children: [
                makeNode(
                    runtimeId: "child",
                    viewType: "ChildView",
                    frame: Rect(x: 10, y: 10, width: 50, height: 20)
                )
            ]
        )
        let window = AdaUIDebug3DWindowSnapshot(
            id: RID(),
            title: "Test",
            frame: Rect(x: 0, y: 0, width: 320, height: 240),
            roots: [root]
        )

        let items = AdaUIDebug3DLayout.project(
            windows: [window],
            projection: AdaUIDebug3DProjection(
                zoom: 1,
                layerSpacing: 12,
                pan: .zero,
                viewportSize: Size(width: 500, height: 400),
                depthLimit: 10
            )
        )

        #expect(items.map(\.runtimeId) == ["child"])
        #expect(items[0].depth == 1)
    }

    @Test
    func pickingPrefersDeeperOverlappingLayer() {
        let shallow = AdaUIDebug3DLayout.Item(
            id: "root",
            windowId: RID(),
            runtimeId: "root",
            label: "Root",
            rect: Rect(x: 0, y: 0, width: 100, height: 100),
            sourceFrame: Rect(x: 0, y: 0, width: 100, height: 100),
            depth: 0,
            color: .white,
            isSelected: false,
            isInteractable: false
        )
        let deep = AdaUIDebug3DLayout.Item(
            id: "child",
            windowId: shallow.windowId,
            runtimeId: "child",
            label: "Child",
            rect: Rect(x: 20, y: 20, width: 60, height: 60),
            sourceFrame: Rect(x: 20, y: 20, width: 60, height: 60),
            depth: 3,
            color: .white,
            isSelected: false,
            isInteractable: false
        )

        #expect(AdaUIDebug3DLayout.pick(Point(30, 30), in: [shallow, deep])?.runtimeId == "child")
        #expect(AdaUIDebug3DLayout.pick(Point(5, 5), in: [shallow, deep])?.runtimeId == "root")
        #expect(AdaUIDebug3DLayout.pick(Point(140, 140), in: [shallow, deep]) == nil)
    }

    @Test
    func integrationBuildsLayoutFromUIContainerSnapshot() {
        let container = UIContainerView(rootView: DebugFixtureView())
        container.frame = Rect(x: 0, y: 0, width: 240, height: 180)
        container.layoutSubviews()

        let roots = container.uiTreeRoots()
        let window = AdaUIDebug3DWindowSnapshot(
            id: RID(),
            title: "Fixture",
            frame: Rect(x: 0, y: 0, width: 240, height: 180),
            roots: roots
        )
        let items = AdaUIDebug3DLayout.project(
            windows: [window],
            projection: AdaUIDebug3DProjection(
                zoom: 1,
                layerSpacing: 16,
                pan: Point(0, 0),
                viewportSize: Size(width: 400, height: 300),
                depthLimit: 20
            )
        )

        #expect(!roots.isEmpty)
        #expect(items.contains(where: { $0.runtimeId == roots[0].runtimeId }))
        #expect(items.contains(where: { $0.label.contains("Button") || $0.label.contains("Text") }))
    }

    private func makeNode(
        runtimeId: String,
        viewType: String,
        frame: Rect,
        children: [UINodeSnapshot] = []
    ) -> UINodeSnapshot {
        UINodeSnapshot(
            runtimeId: runtimeId,
            accessibilityIdentifier: nil,
            nodeType: "AdaUI.ViewNode",
            viewType: viewType,
            frame: frame,
            absoluteFrame: frame,
            canBecomeFocused: false,
            isFocused: false,
            isHidden: nil,
            isInteractable: false,
            parent: nil,
            children: children
        )
    }
}

private struct DebugFixtureView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug")
                .accessibilityIdentifier("title")

            Button(action: {}) {
                Text("Tap")
            }
            .accessibilityIdentifier("button")
        }
        .frame(width: 180, height: 120)
    }
}
