@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorSettingsPage {
    static let runtimeEntry = "RUNTIME ENTRY"
}

extension EditorSettingsWindowViewModel {
    func pages(in section: EditorSettingsSection) -> [String] {
        switch section {
        case .general:
            return editorViewModel == nil ? ["CLOUD ACCOUNT", "APPEARANCE"] : ["CLOUD ACCOUNT", "APPEARANCE", "EDITOR FONT", "SYNTAX APPEARANCE"]
        case .project:
            guard editorViewModel != nil else {
                return []
            }
            var pages = ["PROJECT"]
            if isAdaScriptProject {
                pages += [EditorSettingsPage.runtimeEntry, "RUNTIME PROFILE", "FEATURE PLUGINS"]
                if isRuntimePluginEnabled(.physics2D) {
                    pages.append("PHYSICS 2D")
                }
                pages.append("DISPLAY")
            }
            pages += ["INPUT BINDINGS", "RESOURCE ROOTS", "BUILD FILE SELECTION", "RUN DESTINATION"]
            if !isAdaScriptProject {
                pages.append("LAUNCH")
            }
            return pages
        case .agent:
            return ["AGENTS", "ACP CONNECTION", "PERMISSIONS", "CONTEXT"]
        case .achievements,
            .notifications:
            return []
        }
    }

    func showsPage(_ title: String) -> Bool {
        (selectedPage ?? pages(in: selectedSection).first) == title
    }

    func visiblePages(in section: EditorSettingsSection) -> [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty || section.title.localizedCaseInsensitiveContains(query) {
            return pages(in: section)
        }
        return pages(in: section).filter { $0.localizedCaseInsensitiveContains(query) }
    }

    func activateSection(_ section: EditorSettingsSection) {
        if pages(in: section).isEmpty {
            selectedSection = section
            selectedPage = nil
        } else if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
    }

    func selectPage(_ page: String, in section: EditorSettingsSection) {
        selectedSection = section
        selectedPage = page
        collapsedSections.remove(section)
    }
}

struct EditorSettingsTree: View {
    let viewModel: EditorSettingsWindowViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(viewModel.filteredSections, id: \.self) { section in
                group(section)
            }
            if viewModel.filteredSections.isEmpty {
                Text("No matching settings").font(.system(size: 11)).padding(8)
            }
        }
        .padding(.horizontal, 6)
    }

    private func group(_ section: EditorSettingsSection) -> some View {
        let hasChildren = !viewModel.pages(in: section).isEmpty
        let expanded = !viewModel.collapsedSections.contains(section)
        return VStack(alignment: .leading, spacing: 1) {
            Button {
                viewModel.activateSection(section)
            } label: {
                HStack(spacing: 6) {
                    Text(hasChildren ? (expanded ? "\u{E5CF}" : "\u{E5CC}") : section.icon)
                        .font(AdaEditorMaterialSymbolFont.font(size: 16))
                        .frame(width: 18)
                    Text(section.title).font(.system(size: 13, weight: .bold))
                    Spacer()
                }
                .padding(.horizontal, 6)
                .frame(height: 30)
                .background(selectionBackground(viewModel.selectedSection == section && viewModel.selectedPage == nil))
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.Settings.Section.\(section.title)")
            if hasChildren && expanded {
                ForEach(viewModel.visiblePages(in: section), id: \.self) { page in
                    Button {
                        viewModel.selectPage(page, in: section)
                    } label: {
                        HStack(spacing: 8) {
                            theme.editorColors.border.frame(width: 1, height: 28)
                            Text(page.localizedCapitalized).font(.system(size: 12))
                            Spacer()
                        }
                        .padding(.leading, 15)
                        .padding(.trailing, 6)
                        .frame(height: 28)
                        .background(selectionBackground(viewModel.selectedSection == section && viewModel.selectedPage == page))
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .accessibilityIdentifier("AdaEditor.Settings.Page.\(page)")
                }
            }
        }
        .foregroundColor(theme.editorColors.text)
    }

    private func selectionBackground(_ selected: Bool) -> some View {
        RoundedRectangleShape(cornerRadius: 4).fill(selected ? theme.editorColors.blue.opacity(0.18) : .clear)
    }
}
