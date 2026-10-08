@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorNewFileDialog: View {
    let viewModel: EditorViewModel

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if viewModel.isNewFileKindPreselected {
                namingDialog
            } else {
                templatePicker
            }
        }
        .keyboardShortcuts([
            KeyboardShortcutAction(.escape) {
                EditorNewFileDialogActions.cancel(viewModel: viewModel, dismiss: dismiss)
            }
        ])
    }

    private var templatePicker: some View {
        GeometryReader { geometry in
            let width = max(0, min(800, geometry.size.width - 32))
            let height = max(0, min(520, geometry.size.height - 32))
            ZStack {
                Color.black.opacity(0.45)
                    .onTapGesture { EditorNewFileDialogActions.cancel(viewModel: viewModel, dismiss: dismiss) }
                    .accessibilityIdentifier("AdaEditor.ProjectTree.New.Dismiss")
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("New File")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(theme.editorColors.text)
                        Text("Choose a template · \(viewModel.newFileLocationTitle)")
                            .font(.system(size: 11))
                            .foregroundColor(theme.editorColors.muted)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 64, alignment: .leading)
                    EditorNewFileMenu(width: width, height: max(0, height - 116)) { kind in
                        viewModel.newFileKind = kind
                        viewModel.newFileErrorMessage = nil
                        viewModel.isNewFileKindPreselected = true
                    }
                    HStack {
                        Spacer()
                        dialogButton(title: "Cancel", isPrimary: false) {
                            EditorNewFileDialogActions.cancel(viewModel: viewModel, dismiss: dismiss)
                        }
                        .accessibilityIdentifier("AdaEditor.NewFile.Cancel")
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                }
                .frame(width: width, height: height)
                .background(RoundedRectangleShape(cornerRadius: 12).fill(theme.editorColors.surfaceElevated))
                .overlay { RoundedRectangleShape(cornerRadius: 12).stroke(theme.editorColors.border, lineWidth: 1) }
                .accessibilityIdentifier("AdaEditor.NewFile.Picker")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var namingDialog: some View {
        ZStack(anchor: .center) {
            Color.black.opacity(0.54)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                Text(viewModel.isNewFileKindPreselected ? "New \(viewModel.newFileKind.title)" : "New File")
                    .font(.system(size: 18))
                    .foregroundColor(theme.editorColors.text)
                    .padding(.bottom, 6)

                Text(viewModel.isNewFileKindPreselected ? viewModel.newFileKind.detail : "Choose a file type and name.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .padding(.bottom, 16)

                Text("File name")
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .padding(.bottom, 6)

                TextField("Name", text: viewModel.newFileNameBinding)
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.text)
                    .textFieldStyle(PlainTextFieldStyle())
                    .frame(height: 32)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
                    .overlay {
                        RoundedRectangleShape(cornerRadius: 6)
                            .stroke(theme.editorColors.border, lineWidth: 1)
                    }
                    .accessibilityIdentifier("AdaEditor.NewFile.Name")

                HStack(spacing: 5) {
                    Text("Location: \(viewModel.newFileLocationTitle)")
                    Spacer()
                    Text(viewModel.newFileExtensionHint)
                }
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.muted)
                .padding(.top, 6)

                if !viewModel.newFilePreviewPath.isEmpty {
                    Text("Preview: \(viewModel.newFilePreviewPath)")
                        .font(.system(size: 10))
                        .foregroundColor(theme.editorColors.muted)
                        .padding(.top, 6)
                        .accessibilityIdentifier("AdaEditor.NewFile.Preview")
                }

                if let errorMessage = viewModel.newFileErrorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 232 / 255, green: 96 / 255, blue: 96 / 255))
                        .padding(.top, 8)
                        .accessibilityIdentifier("AdaEditor.NewFile.Error")
                }

                HStack(spacing: 8) {
                    dialogButton(title: "Templates", isPrimary: false) {
                        viewModel.isNewFileKindPreselected = false
                    }
                    .accessibilityIdentifier("AdaEditor.NewFile.Back")
                    Spacer()
                    dialogButton(title: "Cancel", isPrimary: false) {
                        EditorNewFileDialogActions.cancel(viewModel: viewModel, dismiss: dismiss)
                    }
                    .accessibilityIdentifier("AdaEditor.NewFile.Cancel")

                    dialogButton(title: "Create", isPrimary: true) {
                        EditorNewFileDialogActions.create(viewModel: viewModel, dismiss: dismiss)
                    }
                    .disabled(viewModel.newFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(viewModel.newFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                    .accessibilityIdentifier("AdaEditor.NewFile.Create")
                }
                .padding(.top, 18)
            }
            .padding(22)
            .frame(maxWidth: 440)
            .background(
                RoundedRectangleShape(cornerRadius: 12)
                    .fill(theme.editorColors.surfaceElevated)
            )
            .overlay {
                RoundedRectangleShape(cornerRadius: 12)
                    .stroke(theme.editorColors.border, lineWidth: 1)
            }
            .accessibilityIdentifier("AdaEditor.NewFile.Dialog")
        }
    }

    private func dialogButton(title: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 12))
            .foregroundColor(isPrimary ? theme.editorColors.text : theme.editorColors.muted)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                RoundedRectangleShape(cornerRadius: 6)
                    .fill(isPrimary ? theme.editorColors.blue.opacity(0.28) : theme.editorColors.background)
            )
            .overlay {
                RoundedRectangleShape(cornerRadius: 6)
                    .stroke(isPrimary ? theme.editorColors.blue.opacity(0.72) : theme.editorColors.border, lineWidth: 1)
            }
    }
}

@MainActor
enum EditorNewFileDialogActions {
    static func cancel(viewModel: EditorViewModel, dismiss: DismissAction) {
        viewModel.dismissNewFileDialog()
        dismiss()
    }

    @discardableResult
    static func create(viewModel: EditorViewModel, dismiss: DismissAction) -> Bool {
        guard viewModel.createNewFile() else {
            return false
        }

        dismiss()
        return true
    }
}
