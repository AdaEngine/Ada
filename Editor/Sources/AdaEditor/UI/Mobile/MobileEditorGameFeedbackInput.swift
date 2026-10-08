#if os(iOS)
import AdaEngine
import UIKit

/// A system text input hosted in AdaUI, with UIKit handling keyboard and selection.
struct MobileEditorGameFeedbackInput: UIKitViewRepresentable {
    @Binding var text: String
    let textColor: Color

    func makeUIView(context: Context) -> UIKit.UITextField {
        let field = UIKit.UITextField()
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.font = UIFont(name: "JetBrainsMono-Regular", size: 15) ?? .monospacedSystemFont(ofSize: 15, weight: .regular)
        field.returnKeyType = .done
        field.autocorrectionType = .default
        field.accessibilityIdentifier = "AdaEditor.Mobile.GameFeedbackPrompt"
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UIKit.UITextField, in context: Context) {
        context.coordinator.text = _text
        if field.text != text { field.text = text }
        let color = UIColor(red: CGFloat(textColor.red), green: CGFloat(textColor.green), blue: CGFloat(textColor.blue), alpha: CGFloat(textColor.alpha))
        field.textColor = color
        field.tintColor = color
        field.attributedPlaceholder = NSAttributedString(string: "Describe the change…", attributes: [.foregroundColor: color.withAlphaComponent(0.5)])
        field.isEnabled = context.environment.isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: _text) }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView _: UIKit.UITextField, context _: Context) -> Size {
        Size(width: proposal.width ?? 280, height: proposal.height ?? 48)
    }

    static func dismantleUIView(_ field: UIKit.UITextField, coordinator _: Coordinator) {
        field.resignFirstResponder()
        field.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        @objc func edited(_ field: UIKit.UITextField) { text.wrappedValue = field.text ?? "" }

        func textFieldDidBeginEditing(_ field: UIKit.UITextField) {
            field.reloadInputViews()
        }

        func textFieldShouldReturn(_ field: UIKit.UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
    }
}
#endif
