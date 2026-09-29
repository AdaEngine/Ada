#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import Foundation

struct MobileEditorProjectSettingsScreen: View {
    @Environment(\.theme) private var theme
    @State private var title: String
    @State private var errorMessage = ""
    @State private var confirmsDeletion = false
    let isBusy: Bool
    let rename: (String) throws -> Void
    let delete: () throws -> Void
    let showSessions: () -> Void

    init(project: MobileEditorProject, isBusy: Bool, rename: @escaping (String) throws -> Void, delete: @escaping () throws -> Void, showSessions: @escaping () -> Void) {
        _title = State(initialValue: project.title)
        self.isBusy = isBusy
        self.rename = rename
        self.delete = delete
        self.showSessions = showSessions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Project name")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.editorColors.muted)
                        TextField("Project name", text: $title)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 17))
                            .padding(.horizontal, 12)
                            .frame(height: 48)
                            .background(RoundedRectangleShape(cornerRadius: 12).fill(theme.editorColors.background))
                            .overlay { RoundedRectangleShape(cornerRadius: 12).stroke(theme.editorColors.border, lineWidth: 1).allowsHitTesting(false) }
                            .accessibilityIdentifier("AdaEditor.Mobile.ProjectName")
                        settingsButton("Save name", color: theme.editorColors.blue) {
                            do {
                                try rename(title)
                                errorMessage = "Project renamed."
                            } catch { errorMessage = error.localizedDescription }
                        }
                        .disabled(isBusy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .foregroundColor(theme.editorColors.text)
                    .padding(16)
                }
                settingsButton("Previous sessions", color: theme.editorColors.surface, showsChevron: true, action: showSessions)
                    .accessibilityIdentifier("AdaEditor.Mobile.ProjectSessions")
                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Delete project").font(.system(size: 17, weight: .semibold))
                        Text("Removes this project, its files and saved sessions from this device.")
                            .font(.system(size: 14))
                            .foregroundColor(theme.editorColors.muted)
                        settingsButton("Delete project", color: Color(red: 0.92, green: 0.20, blue: 0.23)) { confirmsDeletion = true }
                            .disabled(isBusy)
                            .accessibilityIdentifier("AdaEditor.Mobile.DeleteProject")
                    }
                    .foregroundColor(theme.editorColors.text)
                    .padding(16)
                }
                if isBusy {
                    Text("Wait for the agent to finish before changing this project.")
                        .foregroundColor(theme.editorColors.muted)
                }
                if !errorMessage.isEmpty {
                    Text(errorMessage).font(MobileEditorFont.font(size: 13)).foregroundColor(theme.editorColors.muted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(theme.editorColors.background)
        .alert("Delete this project?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                do { try delete() } catch { errorMessage = error.localizedDescription }
            }
        } message: {
            Text("The project files and saved sessions will be deleted from this device.")
        }
    }

    private func settingsButton(_ title: String, color: Color, showsChevron: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                if showsChevron {
                    Text("\u{E5CC}").font(AdaEditorMaterialSymbolFont.font(size: 18))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangleShape(cornerRadius: 12).fill(color))
        }
        .buttonStyle(DefaultButtonStyle())
    }
}
#endif
