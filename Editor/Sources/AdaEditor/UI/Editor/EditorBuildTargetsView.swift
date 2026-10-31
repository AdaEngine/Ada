import AdaEngine
import Foundation

struct EditorBuildTargetButton: View {
    let model: EditorBuildTargetsModel
    let enabled: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: { model.isMenuPresented.toggle() }) {
            HStack(spacing: 5) {
                Text("\u{E869}").font(AdaEditorMaterialSymbolFont.font(size: 15))
                Text(model.activeName).font(.system(size: 11, weight: .bold)).lineLimit(1)
                Text("\u{E5CF}").font(AdaEditorMaterialSymbolFont.font(size: 15))
            }
            .foregroundColor(theme.editorColors.text)
            .padding(.horizontal, 8).frame(width: 130, height: 28)
        }
        .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surfaceElevated))
        .overlay { RoundedRectangleShape(cornerRadius: 8).stroke(theme.editorColors.border.opacity(0.72), lineWidth: 1) }
        .disabled(!enabled)
        .accessibilityIdentifier("AdaEditor.BuildTarget.Button")
    }
}

struct EditorBuildTargetMenu: View {
    let viewModel: EditorViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("Build Target")).font(.system(size: 11)).foregroundColor(theme.editorColors.muted).padding(8)
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(viewModel.buildTargets.targets) { target in
                        Button(action: { viewModel.selectBuildTarget(target.id) }) {
                            HStack(spacing: 8) {
                                Text(target.name).lineLimit(1)
                                Spacer()
                                if target.id == viewModel.buildTargets.activeID {
                                    Text("\u{E5CA}")
                                        .font(AdaEditorMaterialSymbolFont.font(size: 15))
                                }
                            }
                            .foregroundColor(target.id == viewModel.buildTargets.activeID ? theme.editorColors.blue : theme.editorColors.text)
                            .padding(.horizontal, 10).frame(width: 250, height: 32)
                        }
                        .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
                        .accessibilityIdentifier("AdaEditor.BuildTarget.Select.\(target.id)")
                    }
                }
            }.frame(height: min(240, Float(viewModel.buildTargets.targets.count) * 34))
            Button(L10n.text("Edit Build Targets…"), action: viewModel.presentBuildTargets)
                .padding(10).foregroundColor(theme.editorColors.blue)
                .accessibilityIdentifier("AdaEditor.BuildTarget.Edit")
        }
        .font(.system(size: 12)).padding(4).frame(width: 258)
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surfaceElevated))
        .overlay { RoundedRectangleShape(cornerRadius: 8).stroke(theme.editorColors.border, lineWidth: 1) }
        .accessibilityIdentifier("AdaEditor.BuildTarget.Menu")
    }
}

struct EditorBuildTargetsDialog: View {
    let viewModel: EditorViewModel
    private var model: EditorBuildTargetsModel { viewModel.buildTargets }
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.5).frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("Build Targets")).font(.system(size: 20, weight: .semibold))
                    Text(L10n.text("Create separate targets for test scenes and your game. Save selects the target shown here."))
                        .font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
                    HStack(alignment: .top, spacing: 20) {
                        targetList.frame(width: 190)
                        ScrollView(.vertical) { settings.padding(.trailing, 8) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(maxHeight: .infinity)
                    if let error = model.errorMessage {
                        Text(error).font(.system(size: 12)).foregroundColor(.red).lineLimit(3)
                            .accessibilityIdentifier("AdaEditor.BuildTargets.Error")
                    }
                    HStack(spacing: 12) {
                        action("Cancel", id: "Cancel") { model.isPresented = false; model.draft = nil }
                        Spacer()
                        action("Save Build Targets", id: "Save", primary: true, viewModel.saveBuildTargets)
                            .disabled(!viewModel.canChangeBuildTarget)
                    }
                }
                .padding(22)
                .frame(width: min(880, geometry.size.width - 32), height: min(720, geometry.size.height - 32))
                .background(RoundedRectangleShape(cornerRadius: 14).fill(theme.editorColors.surfaceElevated))
            }
        }.foregroundColor(theme.editorColors.text)
        .accessibilityIdentifier("AdaEditor.BuildTargets.Dialog")
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.vertical) {
                VStack(spacing: 4) {
                    ForEach(model.draft?.buildTargets ?? []) { target in
                        Button(action: { model.select(target.id) }) {
                            Text(target.name).lineLimit(2).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .background(RoundedRectangleShape(cornerRadius: 6).fill(
                            target.id == model.draft?.activeBuildTargetID ? theme.editorColors.blue.opacity(0.2) : theme.editorColors.surface))
                        .accessibilityIdentifier("AdaEditor.BuildTargets.Row.\(target.id)")
                    }
                }
            }.frame(maxHeight: .infinity)
            action("New Target", id: "Add") { model.add() }
            action("Duplicate Target", id: "Duplicate") { model.add(copy: true) }
            action("Delete Target", id: "Delete", model.remove).disabled((model.draft?.buildTargets.count ?? 0) < 2)
        }.font(.system(size: 12))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Target Name", id: "Name", text: Binding(get: { model.editedTarget?.name ?? "" }, set: { value in model.edit { $0.name = value } }))
            field("Startup Scene", id: "Scene", text: Binding(get: { model.sceneText }, set: setScene))
            sceneList
            Text(L10n.text("Build Configuration")).font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(["debug", "release"], id: \.self) { configuration in
                    action(configuration == "debug" ? "Debug" : "Release", id: configuration,
                           primary: (model.editedTarget?.build.configuration ?? "debug") == configuration) {
                        model.edit { $0.build.configuration = configuration }
                    }
                }
            }
            Text(L10n.text("Run Destination")).font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(EditorRunDestination.toolbarDestinations.filter { $0 != .player }, id: \.self) { destination in
                    action(destination.rawValue, id: destination.rawValue,
                           primary: model.editedTarget?.run.destination == destination.adaProjectDestination) {
                        model.edit { $0.run.destination = destination.adaProjectDestination }
                    }
                }
            }
            if model.draft?.build.system == .swiftpm {
                field("Executable Product", id: "Product", text: Binding(get: { model.productText }, set: { value in
                    model.productText = value
                    model.edit { $0.product = EditorViewModel.optionalText(from: value) }
                }))
            }
            Text(L10n.text("Run Arguments (one per line)")).font(.system(size: 12))
            TextEditor(text: Binding(get: { model.argumentsText }, set: { value in
                model.argumentsText = value
                model.edit { $0.run.arguments = EditorViewModel.lineList(from: value) }
            }), showsLineNumbers: false, showsScrollIndicators: true)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
                .accentColor(theme.editorColors.blue)
                .textEditorColors(TextEditorColors(
                    background: theme.editorColors.surface,
                    border: theme.editorColors.border,
                    focusedBorder: theme.editorColors.blue,
                    gutter: theme.editorColors.muted,
                    gutterRule: .clear,
                    currentLineBackground: .clear,
                    selection: theme.editorColors.blue.opacity(0.25)
                ))
                .frame(height: 64)
                .accessibilityIdentifier("AdaEditor.BuildTargets.Arguments")
            field("Resource Roots", id: "Resources", text: Binding(get: { model.resourceRootsText }, set: { value in
                model.resourceRootsText = value
                model.edit { $0.resourceRoots = EditorViewModel.pathList(from: value) }
            }))
            field("Included Files", id: "Included", text: Binding(get: { model.includedFilesText }, set: { value in
                model.includedFilesText = value
                model.edit { $0.build.includedFiles = EditorViewModel.pathList(from: value) }
            }))
            field("Excluded Files", id: "Excluded", text: Binding(get: { model.excludedFilesText }, set: { value in
                model.excludedFilesText = value
                model.edit { $0.build.excludedFiles = EditorViewModel.pathList(from: value) }
            }))
            Text(L10n.text("Use project-relative paths separated by commas. Empty Included Files uses the project's source folder. Runtime and plugin settings are saved per target in Project Settings."))
                .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sceneList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.projectSidebar.items.filter { $0.kind == .scene }, id: \.id) { item in
                    Button(action: { setScene(item.relativePath) }) {
                        Text(item.relativePath).font(.system(size: 11)).lineLimit(1).padding(5)
                    }.foregroundColor(theme.editorColors.blue)
                        .accessibilityIdentifier("AdaEditor.BuildTargets.Scene.\(item.relativePath)")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 82)
    }

    private func setScene(_ path: String) {
        model.sceneText = path
        model.edit {
            $0.startupScene = EditorViewModel.optionalText(from: path)
            $0.runtime.entry.scene = $0.startupScene
        }
    }

    private func field(_ title: String, id: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr(title)).font(.system(size: 12))
            TextField("", text: text).font(.system(size: 12)).textFieldStyle(PlainTextFieldStyle())
                .padding(.horizontal, 8).frame(height: 32)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
                .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border, lineWidth: 1) }
                .accessibilityIdentifier("AdaEditor.BuildTargets.\(id)")
        }
    }

    private func action(_ title: String, id: String, primary: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(L10n.tr(title), action: action).font(.system(size: 12, weight: .semibold))
            .foregroundColor(primary ? .white : theme.editorColors.text)
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangleShape(cornerRadius: 6).fill(primary ? theme.editorColors.blue : theme.editorColors.surface))
            .accessibilityIdentifier("AdaEditor.BuildTargets.\(id)")
    }
}
