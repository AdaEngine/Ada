@_spi(AdaEngine) import AdaEngine

struct ProjectOpeningRecentProjectRow: View {
    let project: EditorProjectReference
    let viewModel: ProjectOpeningViewModel

    var body: some View {
        let isActive = viewModel.detailProject?.path == project.path
        let availability = viewModel.projectAvailability[project.path]
        let isAvailable = availability?.isAvailable == true

        return Button {
            if isAvailable {
                viewModel.openRecentProject(project)
            }
        } label: {
            ZStack(anchor: .leading) {
                if isActive {
                    AdaColorPalette.accentViolet
                        .frame(width: 2, height: 58)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(project.name)
                            .font(.system(size: 14))
                            .foregroundColor(isAvailable ? .white : AdaColorPalette.muted)
                            .lineLimit(1)
                        Spacer()
                        if availability?.containsSwiftCode == true {
                            Text("SPM")
                                .font(.system(size: 9))
                                .foregroundColor(AdaColorPalette.accentOrange)
                        }
                    }

                    Text(viewModel.abbreviatedPath(for: project))
                        .font(.system(size: 11))
                        .foregroundColor(AdaColorPalette.muted)
                        .lineLimit(1)
                }
                .padding(.leading, 20)
                .padding(.trailing, 20)
                .frame(width: ProjectOpeningLayout.explorerWidth, height: 58, alignment: .leading)
            }
        }
        .buttonStyle(LauncherPlainButtonStyle(active: isActive))
        .opacity(isAvailable ? 1 : 0.45)
        .contextMenu {
            Button("Rename…") { viewModel.beginRenamingProject(project) }
            Divider()
            Button("Remove from Recent Projects", role: .destructive) {
                viewModel.removeRecentProject(project)
            }
        }
        .accessibilityIdentifier("AdaEditor.Launcher.Project.\(project.id)")
    }
}
