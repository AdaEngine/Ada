import AdaUtils
import Testing

@_spi(Internal) @testable import AdaUI

@MainActor
@Suite(.serialized)
struct AlertModifierTests {
    @Test
    func alertPresentsPayloadAndDismissesBindingWhenActionRuns() {
        var isPresented = true
        var didDelete = false
        var captured: AlertPresentation?

        AlertPresentationCenter.showAlert = { presentation in
            captured = presentation
        }

        mount(
            EmptyView()
                .alert("Delete file?", isPresented: Binding(get: { isPresented }, set: { isPresented = $0 })) {
                    Button("Delete", role: .destructive) {
                        didDelete = true
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This cannot be undone.")
                }
        )

        #expect(captured?.title == "Delete file?")
        #expect(captured?.message == "This cannot be undone.")
        #expect(captured?.buttons.map(\.title) == ["Delete", "Cancel"])

        captured?.buttons.first?.action?()

        #expect(isPresented == false)
        #expect(didDelete == true)

        AlertPresentationCenter.showAlert = nil
    }

    @Test
    func presentingDataRequiresNonNilData() {
        var isPresented = true
        var didPresent = false

        AlertPresentationCenter.showAlert = { _ in
            didPresent = true
        }

        mount(
            EmptyView()
                .alert("Missing data", isPresented: Binding(get: { isPresented }, set: { isPresented = $0 }), presenting: Optional<String>.none) { value in
                    Button(value) {}
                } message: { value in
                    Text(value)
                }
        )

        #expect(didPresent == false)
        #expect(isPresented == true)

        AlertPresentationCenter.showAlert = nil
    }

    private func mount<Content: View>(_ content: Content) {
        let inputs = _ViewInputs(parentNode: nil, environment: EnvironmentValues())
        _ = Content._makeView(_ViewGraphNode(value: content), inputs: inputs)
    }
}
