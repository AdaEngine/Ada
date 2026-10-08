@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
@Suite(.serialized)
struct LiveControlUpdatesTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test("closure-bound text refreshes without rebuilding its view", arguments: [false, true])
    func externalTextRefresh(isFocused: Bool) throws {
        let model = ControlValues()
        let tester = ViewTester {
            TextField("", text: Binding(get: { model.text }, set: { model.text = $0; model.writes += 1 }))
                .frame(width: 240, height: 36)
        }
        .setSize(Size(width: 260, height: 80))
        .performLayout()
        let field = try #require(firstTextField(in: tester.containerView.viewTree.rootNode))
        if isFocused { _ = tester.click(at: Point(130, 40)) }
        field.setSelection(to: 5)
        UILayoutDebugCounters.isEnabled = true
        UILayoutDebugCounters.reset()
        defer { UILayoutDebugCounters.isEnabled = false }
        model.text = "42"
        tester.containerView.update(1.0 / 60.0)
        #expect(field.text == "42")
        #expect(field.selectionHead <= 2)
        #expect(model.writes == 0)
        #expect(UILayoutDebugCounters.snapshot.contentInvalidations == 0)
        #expect(firstTextField(in: tester.containerView.viewTree.rootNode) === field)
    }

    @Test("reused stack adopts changed alignment without replacing its child")
    func stackAlignmentRefresh() throws {
        let model = ControlValues()
        let tester = ViewTester { AlignmentControl(model: model) }
            .setSize(Size(width: 100, height: 40))
            .performLayout()
        let thumb = try #require(tester.findNodeById("thumb"))
        let initialX = thumb.absoluteFrame().minX
        for anchor in [AnchorPoint.trailing, .leading, .trailing] {
            model.anchor = anchor
            tester.invalidateContent().performLayout()
            #expect(tester.findNodeById("thumb") === thumb)
            #expect(abs(thumb.absoluteFrame().minX - initialX - (anchor == .trailing ? 20 : 0)) < 0.1)
        }
    }

    private func firstTextField(in node: ViewNode) -> TextFieldViewNode? {
        if let field = node as? TextFieldViewNode { return field }
        return node.transientEnvironmentChildren.lazy.compactMap { firstTextField(in: $0) }.first
    }
}

@MainActor
private final class ControlValues {
    var text = "hello"
    var writes = 0
    var anchor = AnchorPoint.leading
}

private struct AlignmentControl: View {
    let model: ControlValues

    var body: some View {
        ZStack(anchor: model.anchor) {
            Color.gray.frame(width: 30, height: 16)
            Color.white.frame(width: 10, height: 12).id("thumb")
        }
        .frame(width: 30, height: 16)
    }
}
