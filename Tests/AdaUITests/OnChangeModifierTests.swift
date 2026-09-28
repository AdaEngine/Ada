import AdaPlatform
@testable import AdaUI
import Math
import Testing

private struct ReentrantOnChangeRoot: View {
    @State var selection = 0
    @State var preparationCount = 0

    var body: some View {
        Text("Prepared \(preparationCount)")
            .onChange(of: selection) { _, _ in
                // Bound recursion so a regression produces an assertion failure.
                if preparationCount < 3 {
                    preparationCount += 1
                }
            }
    }
}

@MainActor
struct OnChangeModifierTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func stateMutationInCallbackDoesNotRepeatTheSameChange() {
        let root = ReentrantOnChangeRoot()
        let tester = ViewTester(rootView: root)
            .setSize(Size(width: 200, height: 100))
            .performLayout()

        root.selection = 1
        tester.performLayout()
        #expect(root.preparationCount == 1)

        root.selection = 2
        tester.performLayout()
        #expect(root.preparationCount == 2)
    }
}
