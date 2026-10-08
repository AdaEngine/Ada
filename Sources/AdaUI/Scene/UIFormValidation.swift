import AdaUIDescription
import AdaUtils

/// Form checks live in the native scene document, so an exported form keeps its validation.
struct UIFormValidation: View {
    let content: AnyView
    let checks: [UIFormCheck]
    let context: UIBindingContext
    let disablesContent: Bool
    var body: some View {
        let errors = checks.filter { !$0.accepts($0.value.value ?? $0.value.binding.flatMap(context.value)) }.map(\.message)
        VStack(alignment: .leading, spacing: 4) {
            content.disabled(disablesContent && !errors.isEmpty)
            if !errors.isEmpty { Text(errors.joined(separator: "\n")).foregroundColor(.red).fontSize(12) }
        }
    }
}
