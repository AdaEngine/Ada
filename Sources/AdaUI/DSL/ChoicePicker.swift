/// A single-selection control with explicitly labeled, stable choices.
public struct ChoicePicker: View {
    public struct Option: Identifiable, Hashable, Sendable {
        public let label: String
        public let value: String
        public var id: String { value }
        public init(label: String, value: String) { self.label = label; self.value = value }
    }
    private let selection: Binding<String>
    private let options: [Option]
    private let label: String
    private let identifier: String

    /// Selection remains empty until the host or user chooses a value; defaults are never inferred.
    public init(_ label: String = "", selection: Binding<String>, options: [Option], identifier: String = "") {
        self.label = label
        self.selection = selection
        self.options = options
        self.identifier = identifier
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty { Text(label) }
            ForEach(options) { option in
                Button((selection.wrappedValue == option.value ? "✓ " : "○ ") + option.label) {
                    selection.wrappedValue = option.value
                }
                .accessibilityIdentifier(identifier + ".option." + option.value)
            }
        }
    }
}
