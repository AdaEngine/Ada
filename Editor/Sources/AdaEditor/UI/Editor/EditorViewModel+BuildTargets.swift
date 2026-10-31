import AdaEngine
import Foundation

extension EditorViewModel {
    var canChangeBuildTarget: Bool {
        project != nil && workspaceTask == nil && !isProjectRunning && !debugger.isActive && !movieMaker.isBusy && !isAdaPlayerBusy
    }

    func presentBuildTargets() {
        guard canChangeBuildTarget, let projectURL else { return }
        do {
            var settings = try ProjectSystem.loadProject(at: projectURL, fileManager: fileManager)
            if settings.buildTargets.isEmpty {
                settings.run.destination = selectedRunDestination.adaProjectDestination
            }
            buildTargets.begin(settings, product: selectedRunProduct)
        } catch {
            appendOutput(L10n.text("Could not load build targets: \(EditorBuildTargetsModel.errorDetail(error))"))
        }
    }

    func selectBuildTarget(_ id: String) {
        guard canChangeBuildTarget, let projectURL else { return }
        do {
            var settings = try ProjectSystem.loadProject(at: projectURL, fileManager: fileManager)
            try settings.activateBuildTarget(id: id)
            try persistBuildTargets(settings)
        } catch {
            appendOutput(L10n.text("Could not select build target: \(EditorBuildTargetsModel.errorDetail(error))"))
        }
        buildTargets.isMenuPresented = false
    }

    func saveBuildTargets() {
        guard canChangeBuildTarget, let settings = buildTargets.draft else { return }
        do {
            try persistBuildTargets(settings)
            buildTargets.isPresented = false
            buildTargets.draft = nil
        } catch {
            buildTargets.errorMessage = L10n.text("Could not save build targets: \(EditorBuildTargetsModel.errorDetail(error))")
        }
    }

    private func persistBuildTargets(_ settings: AdaProject) throws {
        guard let projectURL else { return }
        let product = settings.activeBuildTarget?.product ?? selectedRunProduct ?? runProducts.first
        let targetName = product.flatMap { packageModel?.executableTargetName(forProductNamed: $0) } ?? selectedRunTargetName ?? ""
        try EditorProjectStore(fileManager: fileManager).saveProjectSettings(settings, at: projectURL, targetName: targetName)
        buildTargets.refresh(try ProjectSystem.loadProject(at: projectURL, fileManager: fileManager))
        selectedRunProduct = product
        let destination = Self.editorRunDestination(from: settings.run.destination)
        selectedRunDestination = EditorRunDestination.availableCases.contains(destination) ? destination : selectedRunDestination
        projectMainSceneText = settings.runtime.entry.scene ?? settings.editor.startupScene ?? ""
        projectResourceRootsText = settings.paths.resourceRoots.joined(separator: "\n")
        projectIncludedFiles = settings.build.includedFiles
        projectExcludedFiles = settings.build.excludedFiles
        projectRunArgumentsText = settings.run.arguments.joined(separator: "\n")
        reloadScriptableObjectSupport()
        refreshProjectFiles(logsRefresh: false)
        if selectedRunDestination == .android { refreshAndroidTargets() }
        appendOutput(L10n.text("Selected build target: \(settings.activeBuildTarget?.name ?? "")"))
        bootstrapWorkspaceIfNeeded(force: true)
    }
}
