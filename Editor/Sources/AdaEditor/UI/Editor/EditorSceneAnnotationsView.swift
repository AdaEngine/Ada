@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorSceneAnnotationEditor: View {
    let agent: EditorAgentViewModel
    var onAdded: (() -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let draft = agent.sceneAnnotations.draft {
                Text(L10n.text("Annotation #\(draft.number): \(draft.context.selectedEntityName)"))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(2)
                TextEditor(L10n.text("What should change here?"), text: Binding(
                    get: { agent.sceneAnnotations.draft?.note ?? "" },
                    set: { agent.sceneAnnotations.draft?.note = String($0.prefix(4000)) }
                ), showsLineNumbers: false)
                .font(.system(size: 13))
                .frame(height: 88)
                .accessibilityIdentifier("AdaEditor.Annotations.Note")
                HStack(spacing: 8) {
                    Button(L10n.text("Cancel")) { agent.sceneAnnotations.draft = nil }
                        .buttonStyle(DefaultButtonStyle())
                        .accessibilityIdentifier("AdaEditor.Annotations.Cancel")
                    Spacer()
                    Button(L10n.text("Add to message")) {
                        if agent.sceneAnnotations.add(to: &agent.prompt) { onAdded?() }
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .foregroundColor(theme.editorColors.blue)
                    .disabled(draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("AdaEditor.Annotations.Add")
                }
                .font(.system(size: 12))
            }
            if let error = agent.sceneAnnotations.error {
                Text(L10n.tr(error)).font(.system(size: 11)).foregroundColor(theme.editorColors.purple).lineLimit(3)
            }
        }
        .padding(12)
        .foregroundColor(theme.editorColors.text)
        .background(RoundedRectangleShape(cornerRadius: 9).fill(theme.editorColors.surfaceElevated))
        .overlay { RoundedRectangleShape(cornerRadius: 9).stroke(theme.editorColors.border, lineWidth: 1) }
        .keyboardShortcuts([KeyboardShortcutAction(.escape, action: { agent.sceneAnnotations.draft = nil })])
        .accessibilityIdentifier("AdaEditor.Annotations.Editor")
    }
}

struct EditorSceneAnnotationChips: View {
    let agent: EditorAgentViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !agent.sceneAnnotations.items.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(agent.sceneAnnotations.items) { item in
                            HStack(spacing: 4) {
                                Button(action: { agent.sceneAnnotations.edit(item.id, prompt: agent.prompt) }) {
                                    Text("#\(item.number) · \(item.context.selectedEntityName)").lineLimit(1)
                                }
                                .buttonStyle(DefaultButtonStyle())
                                .accessibilityIdentifier("AdaEditor.Annotations.Edit.\(item.number)")
                                Button(action: { agent.sceneAnnotations.remove(item.id, from: &agent.prompt) }) {
                                    Text("×").font(.system(size: 15))
                                }
                                .buttonStyle(DefaultButtonStyle())
                                .accessibilityIdentifier("AdaEditor.Annotations.Remove.\(item.number)")
                            }
                            .font(.system(size: 11))
                            .foregroundColor(theme.editorColors.blue)
                            .padding(7)
                            .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.blue.opacity(0.12)))
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .frame(height: 34)
                .accessibilityIdentifier("AdaEditor.Annotations.Chips")
            }
            if agent.sceneAnnotations.draft?.editingID != nil {
                EditorSceneAnnotationEditor(agent: agent)
            } else if let error = agent.sceneAnnotations.error {
                Text(L10n.tr(error)).font(.system(size: 11)).foregroundColor(theme.editorColors.purple).lineLimit(3)
            }
        }
    }
}
