import AdaEngine
import Foundation
import Observation

@Observable
@MainActor
final class EditorInputBindingsDraft {
    struct Action: Identifiable {
        let id = UUID()
        var name: String
        var bindings: [InputBinding]
        var deadZone: Float
    }

    var actions: [Action]

    init(actions: [InputAction] = []) {
        self.actions = actions.map { Action(name: $0.name, bindings: $0.bindings, deadZone: $0.deadZone) }
    }

    func validatedActions() throws -> [InputAction] {
        let result = actions.map {
            InputAction(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), bindings: $0.bindings, deadZone: $0.deadZone)
        }
        try InputAction.validate(result)
        return result
    }

    func addAction() {
        var name = "NewAction"
        var suffix = 2
        while actions.contains(where: { $0.name == name }) {
            name = "NewAction\(suffix)"
            suffix += 1
        }
        actions.append(Action(name: name, bindings: [], deadZone: 0.2))
    }

    func edit(_ id: UUID, _ change: (inout Action) -> Void) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&actions[index])
    }

    func addBinding(_ binding: InputBinding, to id: UUID) {
        edit(id) {
            if !$0.bindings.contains(binding) {
                $0.bindings.append(binding)
            }
        }
    }
}

private struct EditorInputBindingOption: Sendable {
    let title: String
    let binding: InputBinding

    static let groups: [(String, [Self])] = [
        (
            "Keyboard",
            KeyCode.allCases.filter { $0 != .none }
                .map {
                    Self(title: label(String(describing: $0)), binding: .key($0))
                }
        ),
        (
            "Mouse",
            [
                Self(title: "Left Button", binding: .mouseButton(.left)),
                Self(title: "Right Button", binding: .mouseButton(.right)),
                Self(title: "Middle Button", binding: .mouseButton(.middle)),
                Self(title: "Wheel Positive", binding: .mouseScroll(.positive)),
                Self(title: "Wheel Negative", binding: .mouseScroll(.negative)),
                Self(title: "Movement", binding: .mouseMotion),
            ]
        ),
        (
            "Gamepad",
            GamepadButton.allCases.filter { $0 != .unknown }
                .map {
                    Self(title: label($0.rawValue), binding: .gamepadButton($0))
                }
                + GamepadAxis.allCases.filter { $0 != .unknown }
                .flatMap { axis in
                    InputAxisDirection.allCases.map {
                        Self(title: "\(label(axis.rawValue)) \($0 == .positive ? "+" : "−")", binding: .gamepadAxis(axis, $0))
                    }
                }
        ),
        (
            "Touch",
            [Self(title: "Any Finger Held", binding: .touch)]
                + InputTouchPhase.allCases.map {
                    Self(title: label($0.rawValue), binding: .touchEvent($0))
                }
        ),
    ]

    private static func label(_ value: String) -> String {
        value.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }

    static func group(for binding: InputBinding) -> String {
        groups.first { $0.1.contains { $0.binding == binding } }?.0 ?? "Keyboard"
    }

    static func options(_ group: String) -> [Self] {
        groups.first { $0.0 == group }?.1 ?? []
    }
}

struct EditorInputBindingsSettings: View {
    let draft: EditorInputBindingsDraft
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("INPUT BINDINGS").font(.system(size: 11)).foregroundColor(theme.editorColors.blue)
                Spacer()
                button("+ Action", id: "AddAction", action: draft.addAction)
            }
            Divider()
            Text("Name an action, then bind keyboard, mouse, gamepad or touch inputs. Any binding can activate it.")
                .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            if draft.actions.isEmpty {
                Text("No actions yet. Add an action such as Jump, MoveLeft or Interact.")
                    .font(.system(size: 12)).foregroundColor(theme.editorColors.muted).padding(.vertical, 12)
            }
            ForEach(draft.actions) { action in
                actionCard(action)
            }
        }
        .accessibilityIdentifier("AdaEditor.Settings.InputBindings")
    }

    private func actionCard(_ action: EditorInputBindingsDraft.Action) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(
                    "Action name",
                    text: Binding(
                        get: { draft.actions.first { $0.id == action.id }?.name ?? "" },
                        set: { value in draft.edit(action.id) { $0.name = value } }
                    )
                )
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 13)).padding(.horizontal, 8).frame(height: 32)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surfaceElevated))
                .accessibilityIdentifier("AdaEditor.Settings.InputBindings.Name.\(action.name)")
                button("Remove Action", id: "RemoveAction.\(action.name)") {
                    draft.actions.removeAll { $0.id == action.id }
                }
            }
            ForEach(Array(action.bindings.indices), id: \.self) { index in
                bindingRow(action, index: index)
            }
            HStack(spacing: 6) {
                ForEach(EditorInputBindingOption.groups.map(\.0), id: \.self) { group in
                    button("+ \(group)", id: "Add\(group).\(action.name)") {
                        if let option = EditorInputBindingOption.options(group).first(where: { !action.bindings.contains($0.binding) }) {
                            draft.addBinding(option.binding, to: action.id)
                        }
                    }
                }
            }
            if action.bindings.contains(where: {
                if case .gamepadAxis = $0 {
                    return true
                }
                return false
            }) {
                HStack(spacing: 8) {
                    Text("Gamepad Dead Zone").font(.system(size: 11))
                    EditorEnumField(
                        cases: ["0.0", "0.1", "0.2", "0.3", "0.4", "0.5"],
                        selection: Binding(
                            get: { String(action.deadZone) },
                            set: { value in
                                if let number = Float(value) {
                                    draft.edit(action.id) { $0.deadZone = number }
                                }
                            }
                        )
                    )
                    .frame(width: 90)
                }
            }
        }
        .foregroundColor(theme.editorColors.text)
        .padding(10)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
        .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border, lineWidth: 1) }
    }

    private func bindingRow(_ action: EditorInputBindingsDraft.Action, index: Int) -> some View {
        let binding = action.bindings[index]
        let group = EditorInputBindingOption.group(for: binding)
        let options = EditorInputBindingOption.options(group)
        return HStack(spacing: 8) {
            Text(group).font(.system(size: 11)).frame(width: 75, alignment: .leading)
            EditorEnumField(
                cases: options.map(\.title),
                selection: Binding(
                    get: { options.first { $0.binding == binding }?.title ?? "" },
                    set: { title in
                        guard let selected = options.first(where: { $0.title == title }) else {
                            return
                        }
                        draft.edit(action.id) {
                            guard $0.bindings.indices.contains(index) else {
                                return
                            }
                            $0.bindings[index] = selected.binding
                        }
                    }
                ),
                accessibilityID: "AdaEditor.Settings.InputBindings.Binding.\(action.name).\(index)"
            )
            button("−", id: "RemoveBinding.\(action.name).\(index)") {
                draft.edit(action.id) {
                    if $0.bindings.indices.contains(index) {
                        $0.bindings.remove(at: index)
                    }
                }
            }
        }
    }

    private func button(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11)).padding(.horizontal, 8).frame(height: 28)
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Settings.InputBindings.\(id)")
    }
}
