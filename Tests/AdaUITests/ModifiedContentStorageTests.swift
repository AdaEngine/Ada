@testable import AdaPlatform
@testable import AdaUI
import Testing

@MainActor
struct ModifiedContentStorageTests {
    init() throws {
        try Application.prepareForTest()
    }

    @Test
    func nestedModifiersHaveBoundedInlineSize() {
        let view = paddedView
        // The same concrete chain used to occupy hundreds of kilobytes inline.
        // Keep this independent of pointer size and the storage implementation.
        #expect(MemoryLayout.size(ofValue: view) <= 256)
        #expect(MemoryLayout.size(ofValue: view.padding(1).onAppear {}) <= 256)
    }

    @Test
    func nestedModifiersBuildAndRebuildWithCorrectLayout() {
        let tester = ViewTester(rootView: paddedView)
        let size = tester.containerView.viewTree.rootNode.contentNode.sizeThatFits(.infinity)
        #expect(size.width == 104)
        #expect(size.height == 44)

        tester.invalidateContent().performLayout()
        let updatedSize = tester.containerView.viewTree.rootNode.contentNode.sizeThatFits(.infinity)
        #expect(updatedSize == size)
    }

    @Test
    func copiesAndWritableKeyPathsPreserveValueSemantics() {
        let original = ModifiedContent(content: [1, 2], modifier: [3, 4])
        var copy = original
        copy.content.append(5)
        copy[keyPath: \.modifier].append(6)

        #expect(original.content == [1, 2])
        #expect(original.modifier == [3, 4])
        #expect(copy.content == [1, 2, 5])
        #expect(copy.modifier == [3, 4, 6])

        var nested = ModifiedContent(content: original, modifier: 0)
        let nestedCopy = nested
        nested.content.content.append(7)
        #expect(nestedCopy.content.content == [1, 2])
        #expect(nested.content.content == [1, 2, 7])
    }

    @Test
    func concatenatedCustomModifiersKeepTheirOrder() {
        let tester = ViewTester {
            EmptyView().modifier(WidthModifier(width: 40).concat(InsetModifier(inset: 3)))
        }
        let size = tester.containerView.viewTree.rootNode.contentNode.sizeThatFits(.infinity)
        #expect(size.width == 46)
        #expect(size.height == 26)
    }

    private var paddedView: some View {
        EmptyView()
            .frame(width: 80, height: 20)
            .padding(1)
            .padding(1)
            .padding(1)
            .padding(1)
            .padding(1)
            .padding(1)
            .padding(1)
            .padding(1)
            .padding(1)
            .padding(1)
            .padding(1)
            .padding(1)
    }
}

private struct WidthModifier: ViewModifier {
    let width: Float

    func body(content: Content) -> some View {
        content.frame(width: width, height: 20)
    }
}

private struct InsetModifier: ViewModifier {
    let inset: Float

    func body(content: Content) -> some View {
        content.padding(inset)
    }
}
