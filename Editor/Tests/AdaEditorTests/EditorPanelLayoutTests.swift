@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Math
import Observation
import Testing

@testable import AdaEditor

@Suite("Observed panel layouts", .serialized)
@MainActor
struct EditorPanelLayoutTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "PanelLayoutTests")))
        }
    }

    @Test("preview resizing changes geometry while retaining content")
    func previewResize() async throws {
        let state = EditorPreviewResizeState()
        let builds = PanelLayoutBuildCounter()
        let container = makeContainer(
            EditorPreviewPanelsLayout(state: state) {
                PanelLayoutProbe(counter: builds).accessibilityIdentifier("editor")
                Color.clear
                PanelLayoutProbe(counter: builds).accessibilityIdentifier("preview")
            }
        )
        let original = try container.uiNode(matching: .accessibilityIdentifier("preview"))
        let originalBuilds = builds.count
        for delta in [Float(-50), -120, -200, 100] {
            state.resize(translation: delta, availableWidth: 1000)
            await settle(container)
            let preview = try container.uiNode(matching: .accessibilityIdentifier("preview"))
            #expect(preview.runtimeId == original.runtimeId)
            #expect(preview.absoluteFrame.width == EditorPreviewSplitLayout.previewWidth(requestedWidth: 360 - delta, availableWidth: 1000))
        }
        #expect(builds.count == originalBuilds)
    }

    @Test("observable intrinsic layout size invalidates ancestor measurement without rebuilding content")
    func intrinsicLayoutSize() async throws {
        let state = PanelLayoutDimensions()
        let builds = PanelLayoutBuildCounter()
        let container = makeContainer(
            HStack(spacing: 0) {
                IntrinsicPanelLayout(state: state) {
                    PanelLayoutProbe(counter: builds)
                }
                .accessibilityIdentifier("sized")
                Color.red.frame(width: 20, height: 20).accessibilityIdentifier("neighbor")
            }
        )
        let oldSize = try container.uiNode(matching: .accessibilityIdentifier("sized"))
        let oldNeighbor = try container.uiNode(matching: .accessibilityIdentifier("neighbor"))
        let originalBuilds = builds.count
        state.width += 80
        await settle(container)
        let resized = try container.uiNode(matching: .accessibilityIdentifier("sized"))
        let neighbor = try container.uiNode(matching: .accessibilityIdentifier("neighbor"))
        #expect(resized.absoluteFrame.width == oldSize.absoluteFrame.width + 80)
        #expect(neighbor.absoluteFrame.minX > oldNeighbor.absoluteFrame.minX)
        #expect(builds.count == originalBuilds)
    }

    private func makeContainer<V: View>(_ view: V) -> UIContainerView<V> {
        let container = UIContainerView(rootView: view)
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 600)
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
private final class PanelLayoutBuildCounter {
    var count = 0
}

private struct PanelLayoutProbe: View {
    let counter: PanelLayoutBuildCounter
    var body: some View {
        counter.count += 1
        return Color.blue.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

@Observable
@MainActor
private final class PanelLayoutDimensions {
    var width: Float = 100
}

private struct IntrinsicPanelLayout: Layout {
    let state: PanelLayoutDimensions

    func sizeThatFits(_: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> Size {
        Size(width: state.width, height: 30)
    }

    func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var childProposal = proposal
        childProposal.width = bounds.width
        childProposal.height = bounds.height
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: childProposal)
    }
}
