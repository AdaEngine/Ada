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
            VStack(alignment: .leading, spacing: 22) {
                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Project name").font(MobileEditorFont.font(size: 14))
                        TextField("Project name", text: $title)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(MobileEditorFont.font(size: 16))
                            .frame(height: 48)
                            .background(theme.editorColors.background)
                            .accessibilityIdentifier("AdaEditor.Mobile.ProjectName")
                        MobileEditorPrimaryButton(title: "Save name") {
                            do {
                                try rename(title)
                                errorMessage = "Project renamed."
                            } catch { errorMessage = error.localizedDescription }
                        }
                        .disabled(isBusy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .foregroundColor(theme.editorColors.text)
                    .padding(17)
                }
                MobileEditorPrimaryButton(title: "Previous sessions", action: showSessions)
                    .accessibilityIdentifier("AdaEditor.Mobile.ProjectSessions")
                MobileEditorCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Delete project").font(MobileEditorFont.font(size: 16))
                        Text("Removes this project, its files and saved sessions from this device.")
                            .font(MobileEditorFont.font(size: 13))
                            .foregroundColor(theme.editorColors.muted)
                        Button("Delete project", role: .destructive) { confirmsDeletion = true }
                            .foregroundColor(.red)
                            .disabled(isBusy)
                            .accessibilityIdentifier("AdaEditor.Mobile.DeleteProject")
                    }
                    .foregroundColor(theme.editorColors.text)
                    .padding(17)
                }
                if isBusy {
                    Text("Wait for the agent to finish before changing this project.")
                        .foregroundColor(theme.editorColors.muted)
                }
                if !errorMessage.isEmpty {
                    Text(errorMessage).font(MobileEditorFont.font(size: 13)).foregroundColor(theme.editorColors.muted)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
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
}
#endif
