@_spi(AdaEngine) import AdaEngine

struct EditorProjectToolSidebar: View {
    let viewModel: EditorViewModel

    @Environment(\.metrics) private var metrics
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            adaEditorPanelTitle(title, trailing: viewModel.workspaceStatus.title, theme: theme)
            content
            if viewModel.toolStrip.activeRightTool != "swiftPackageTasks" && viewModel.toolStrip.activeRightTool != "projectDependencies" {
                Spacer()
            }
        }
        .background(
            RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner)
                .fill(theme.editorColors.surfaceElevated)
        )
    }

    private var title: String {
        switch viewModel.toolStrip.activeRightTool {
        case "projectDependencies":
            "DEPENDENCIES"
        case "swiftPackageTasks":
            "TASK RUNNER"
        default:
            "PROJECT"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.toolStrip.activeRightTool {
        case "projectDependencies":
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    EditorLibrariesView(viewModel: viewModel.libraries)
                        .padding(12)
                        .onAppear { viewModel.libraries.load(for: viewModel) }
                    if let packageModel = viewModel.packageModel {
                        section("PRODUCTS") {
                            ForEach(packageModel.products, id: \.name) { product in
                                row("\(product.name) · \(product.type)")
                            }
                        }
                        section("DEPENDENCIES") {
                            ForEach(packageModel.dependencies, id: \.identity) { dependency in
                                dependencyRow(dependency)
                            }
                        }
                        section("ADD PACKAGE") {
                            input("URL or local path", text: viewModel.dependencyLocationBinding)
                            input("Requirement, e.g. from: \"1.0.0\"", text: viewModel.dependencyRequirementBinding)
                            command("Add Dependency") { viewModel.addProjectDependency() }
                            if !viewModel.dependencyStatusMessage.isEmpty {
                                row(viewModel.dependencyStatusMessage)
                            }
                        }
                        section("PLUGINS") {
                            ForEach(packageModel.pluginTargets, id: \.self) { plugin in
                                row(plugin)
                            }
                        }
                    } else if !isAdaScriptProject {
                        section("PACKAGE") {
                            row("Package model is not loaded yet.")
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        case "swiftPackageTasks":
            EditorTaskRunner(
                groups: EditorTaskRunnerGroup.swiftPackage(products: viewModel.runProducts),
                isEnabled: viewModel.workspaceTask == nil,
                onRun: runTask
            )
        default:
            section("STATUS") {
                row(viewModel.workspaceStatus.title)
            }
        }
    }

    private var isAdaScriptProject: Bool {
        viewModel.projectURL.flatMap { try? ProjectSystem.loadProject(at: $0).build.system.isAdaScript } ?? false
    }

    private func runTask(_ id: String) {
        switch id {
        case "build": viewModel.buildAll()
        case "test": viewModel.runTests()
        case "runSelected": viewModel.runSelectedTarget()
        case "resolve": viewModel.bootstrapWorkspaceIfNeeded(force: true)
        case "update": viewModel.updateDependencies()
        case "clean": viewModel.cleanPackageCache()
        case "reset": viewModel.resetPackageCache()
        default:
            guard id.hasPrefix("product:") else {
                return
            }
            viewModel.selectedRunProduct = String(id.dropFirst("product:".count))
            viewModel.runSelectedTarget()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.blue)
            content()
        }
        .padding(12)
    }

    private func row(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(theme.editorColors.muted)
            .lineLimit(2)
            .lineBreakMode(.byCharWrapping)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func dependencyRow(_ dependency: SwiftPackageDependency) -> some View {
        HStack(spacing: 6) {
            row(dependency.url ?? dependency.path ?? dependency.identity)
            if dependency.identity.lowercased() == "adaengine" {
                Text("Managed")
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.muted)
            } else {
                Button(action: { viewModel.removeProjectDependency(identity: dependency.identity) }) {
                    Text("Remove")
                        .font(.system(size: 10))
                        .foregroundColor(theme.editorColors.blue)
                }
                .buttonStyle(DefaultButtonStyle())
            }
        }
    }

    private func input(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(size: 11))
            .foregroundColor(theme.editorColors.text)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangleShape(cornerRadius: 6)
                    .fill(theme.editorColors.surface)
            )
    }

    private func command(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.blue)
                .frame(height: 24, alignment: .leading)
        }
        .buttonStyle(DefaultButtonStyle())
    }
}
