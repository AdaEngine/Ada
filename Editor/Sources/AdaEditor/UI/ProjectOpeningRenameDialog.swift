@_spi(AdaEngine) import AdaEngine
import Foundation

struct ProjectOpeningRenameDialog: View {
    let viewModel: ProjectOpeningViewModel

    var body: some View {
        ZStack(anchor: .center) {
            Color.black.opacity(0.54)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename Project")
                    .font(.system(size: 18))
                Text("Choose a display name. The project folder stays in its current location.")
                    .font(.system(size: 12))
                    .foregroundColor(AdaColorPalette.muted)
                TextField("Project name", text: viewModel.renamedProjectNameBinding)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 14))
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                    .background(RoundedRectangleShape(cornerRadius: 6).fill(AdaColorPalette.input))
                    .accessibilityIdentifier("AdaEditor.Launcher.Rename.Name")
                if let error = viewModel.recentProjectError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(AdaColorPalette.accentOrange)
                }
                actions
            }
            .foregroundColor(.white)
            .padding(.all, 24)
            .frame(width: 420)
            .background(RoundedRectangleShape(cornerRadius: 12).fill(AdaColorPalette.window))
            .accessibilityIdentifier("AdaEditor.Launcher.Rename.Dialog")
        }
    }

    private var actions: some View {
        HStack(spacing: 16) {
            Spacer()
            Button("Cancel") { viewModel.cancelRenamingProject() }
                .accessibilityIdentifier("AdaEditor.Launcher.Rename.Cancel")
            Button("Rename") { viewModel.renameRecentProject() }
                .disabled(viewModel.renamedProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("AdaEditor.Launcher.Rename.Save")
        }
        .font(.system(size: 14))
    }
}
