//
//  Toggle.swift
//  AdaEngine
//

/// A control that switches a Boolean value on or off.
///
/// The binding is the source of truth. Use ``View/toggleStyle(_:)`` to change
/// the control's appearance without changing its behavior.
public struct Toggle<Label: View>: View {
    private let isOn: Binding<Bool>
    private let label: Label

    /// Creates a toggle with a custom label.
    ///
    /// - Parameters:
    ///   - isOn: A binding to the value the toggle controls.
    ///   - label: A view that describes the setting.
    @MainActor
    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.label = label()
    }

    public var body: some View {
        ToggleStyledContent(isOn: isOn, label: label)
    }
}

extension Toggle where Label == Text {
    /// Creates a toggle with a text label.
    ///
    /// - Parameters:
    ///   - title: A description of the setting.
    ///   - isOn: A binding to the value the toggle controls.
    @MainActor
    public init(_ title: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title) }
    }
}

private struct ToggleStyledContent<Label: View>: View {
    @Environment(\.toggleStyle) private var style
    @Environment(\.toggleLabelsHidden) private var labelsHidden

    let isOn: Binding<Bool>
    let label: Label

    var body: some View {
        AnyView(style.makeBody(configuration: ToggleStyleConfiguration(
            isOn: isOn,
            label: AnyView(label),
            showsLabel: !labelsHidden
        )))
    }
}
