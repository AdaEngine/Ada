@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

extension EditorViewModel {
    func startEditorSessionIfNeeded() {
        guard !didStartEditorSession else {
            return
        }

        RuntimeLogStore.shared.setEnabled(true)
        didStartEditorSession = true
        bootstrapWorkspaceIfNeeded()
        refreshSourceControl()
    }

    func bootstrapWorkspaceIfNeeded(force: Bool = false) {
        guard workspaceTask == nil, let projectURL else {
            return
        }
        guard force || workspaceStatus == .idle || packageModel == nil else {
            return
        }

        if let settings = try? ProjectSystem.loadProject(at: projectURL, fileManager: fileManager) {
            if settings.build.system == .adaScript {
                buildAdaScriptProject(settings, at: projectURL, statusTitle: "Prepare AdaScript Workspace")
                return
            }
            #if os(iOS)
                do {
                    try ProjectSystem.validateRunCompatibility(
                        of: settings,
                        at: projectURL,
                        destination: .iPadOS,
                        fileManager: fileManager
                    )
                } catch {
                    workspaceStatus = .failed(error.message)
                    footer.setWorkspaceFooterTitle(workspaceStatus.title)
                    appendOutput(error.message)
                    return
                }
            #endif
        }

        guard EditorDistribution.current.supportsSwiftProjects else {
            workspaceStatus = .failed(EditorDistributionError.swiftProjectsMessage)
            footer.setWorkspaceFooterTitle(workspaceStatus.title)
            appendOutput(EditorDistributionError.swiftProjectsMessage)
            return
        }

        workspaceStatus = .resolving
        buildActivity = EditorBuildActivity(title: "Prepare Workspace")
        footer.setWorkspaceFooterTitle("Workspace: Preparing")
        lastLoggedWorkspaceProgressPhase = nil
        appendOutput("Loading \(ProjectSystem.metadataFileName) and resolving SwiftPM dependencies...")

        workspaceTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.workspaceService.setDiagnosticsHandler { [weak self] uri, diagnostics in
                await MainActor.run {
                    self?.receiveSourceDiagnostics(diagnostics, uri: uri)
                }
            }
            let result = await self.workspaceService.bootstrap(projectURL: projectURL) { progress in
                await MainActor.run {
                    self.handleWorkspaceProgress(progress)
                }
            }
            await MainActor.run {
                self.packageModel = result.packageModel
                self.replaceBuildDiagnostics(with: result.diagnostics)
                self.showProblemsIfNeeded()
                let failureOutput =
                    result.describeResult.combinedOutput.isEmpty
                    ? result.resolveResult.combinedOutput
                    : result.describeResult.combinedOutput
                self.workspaceStatus = result.succeeded ? .ready : .failed(failureOutput)
                self.footer.setWorkspaceFooterTitle(self.workspaceStatus.title)
                self.selectedRunProduct = self.selectedRunProduct ?? self.runProducts.first
                self.appendOutput(result.resolveResult)
                self.appendOutput(result.describeResult)
                if let indexBuildResult = result.indexBuildResult {
                    self.workspaceStatus = indexBuildResult.succeeded ? .ready : .failed(indexBuildResult.combinedOutput)
                    self.footer.setWorkspaceFooterTitle(self.workspaceStatus.title)
                    self.appendOutput(indexBuildResult)
                }
                self.buildActivity?
                    .finish(
                        succeeded: result.succeeded && result.indexBuildResult?.succeeded != false
                    )
                self.workspaceTask = nil
                self.refreshPreviewForActiveDocument()
            }
        }
    }

    func refreshSourceControl() {
        guard EditorDistribution.current.supportsSwiftProjects else {
            return
        }
        guard !sourceControl.isRunning else {
            return
        }
        sourceControl.refreshTask?.cancel()
        let generation = UUID()
        sourceControl.refreshGeneration = generation
        guard let projectURL else {
            sourceControl.snapshot = .empty
            sourceControl.statusMessage = "No project is open."
            footer.setSourceControlFooterTitle(nil)
            updateOpenGitReviews()
            return
        }
        sourceControl.isRefreshing = true
        sourceControl.statusMessage = "Refreshing source control…"
        sourceControl.refreshTask = Task { [weak self, sourceControlService] in
            let result = await sourceControlService.snapshot(projectURL: projectURL)
            guard let self, self.projectURL == projectURL, self.sourceControl.refreshGeneration == generation, !Task.isCancelled else {
                return
            }
            self.sourceControl.snapshot = result.snapshot
            self.sourceControl.statusMessage = self.sourceControlStatusMessage(for: result)
            self.sourceControl.isRefreshing = false
            self.footer.setSourceControlFooterTitle(result.snapshot.footerTitle)
            if !result.succeeded {
                self.appendOutput(result.statusResult)
            }
            self.updateOpenGitReviews()
        }
    }

    func stageSourceControlFile(_ path: String) {
        executeSourceControlCommand(.stage(paths: [path]), statusTitle: "Stage \(path)")
    }

    func stageAllSourceControlFiles() {
        executeSourceControlCommand(.stage(paths: []), statusTitle: "Stage All")
    }

    func unstageSourceControlFile(_ path: String) {
        executeSourceControlCommand(.unstage(paths: [path]), statusTitle: "Unstage \(path)")
    }

    func unstageAllSourceControlFiles() {
        executeSourceControlCommand(.unstage(paths: []), statusTitle: "Unstage All")
    }

    func stashSourceControlChanges() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        executeSourceControlCommand(.stash(message: "AdaEditor stash \(timestamp)"), statusTitle: "Stash")
    }

    func commitSourceControlChanges() {
        let message = sourceControl.trimmedCommitMessage
        guard !message.isEmpty else {
            sourceControl.statusMessage = "Enter a commit message."
            return
        }

        guard !sourceControl.snapshot.stagedFiles.isEmpty else {
            sourceControl.statusMessage = "Stage files before committing."
            return
        }

        executeSourceControlCommand(.commit(message: message), statusTitle: "Commit", clearsCommitMessage: true)
    }

    func pullSourceControlChanges() {
        executeSourceControlCommand(.pull, statusTitle: "Pull")
    }

    func pushSourceControlChanges() {
        executeSourceControlCommand(.push, statusTitle: "Push")
    }

    func checkoutSourceControlBranch(_ branch: GitBranch) {
        guard !branch.isCurrent else {
            return
        }

        executeSourceControlCommand(.checkout(branch: branch.name), statusTitle: "Checkout \(branch.name)")
    }

    func createSourceControlBranch() {
        let branchName = sourceControl.trimmedNewBranchName
        guard !branchName.isEmpty else {
            sourceControl.statusMessage = "Enter a branch name."
            return
        }

        executeSourceControlCommand(.createBranch(name: branchName), statusTitle: "Create Branch \(branchName)", clearsNewBranchName: true)
    }

    func createSourceControlRepository() {
        executeSourceControlCommand(.initializeRepository, statusTitle: "Create .git")
    }

    func buildAll() {
        if let projectURL,
            let settings = try? ProjectSystem.loadProject(at: projectURL, fileManager: fileManager),
            settings.build.system == .adaScript {
            buildAdaScriptProject(settings, at: projectURL, statusTitle: "Build AdaScript Project")
            return
        }
        executeWorkspaceCommand(.build(target: nil, buildTests: true), statusTitle: "Build")
    }

    func buildTarget(_ target: String) {
        if let projectURL,
            let settings = try? ProjectSystem.loadProject(at: projectURL, fileManager: fileManager),
            settings.build.system == .adaScript {
            buildAdaScriptProject(settings, at: projectURL, statusTitle: "Build AdaScript Project")
            return
        }
        executeWorkspaceCommand(.build(target: target, buildTests: false), statusTitle: "Build \(target)")
    }

    func runSelectedTarget() {
        guard !debugger.isActive else {
            return
        }
        let product = selectedRunProduct ?? runProducts.first
        if workbench.activeDocument?.isDirty == true {
            guard saveActiveDocumentIfNeeded() else {
                let detail = workbench.activeDocumentSaveFailureDescription ?? "the active document could not be saved"
                workspaceStatus = .failed("Run blocked: \(detail)")
                footer.setWorkspaceFooterTitle(workspaceStatus.title)
                appendOutput("Run blocked: \(detail)")
                return
            }
        }
        if selectedRunDestination == .player {
            runOnAdaPlayer()
            return
        }
        let projectSettings = projectURL.flatMap {
            try? ProjectSystem.loadProject(at: $0, fileManager: fileManager)
        }
        if let projectURL,
            let settings = projectSettings,
            settings.build.system == .adaScript,
            selectedRunDestination == .macOS {
            let projectName = settings.project.displayName ?? settings.project.name ?? project?.name ?? "AdaScript Project"
            buildAdaScriptProject(
                settings,
                at: projectURL,
                statusTitle: "Build AdaScript Project"
            ) { [weak self] artifact in
                self?.launchAdaScriptProject(artifact, projectName: projectName)
            }
            return
        }
        if projectSettings?.build.system == .adaScript, selectedRunDestination == .web {
            let message = "Web run is not available for AdaScript projects yet."
            workspaceStatus = .failed(message)
            footer.setWorkspaceFooterTitle(workspaceStatus.title)
            appendOutput(message)
            return
        }
        switch selectedRunDestination {
        case .player:
            runOnAdaPlayer()
        case .macOS:
            executeWorkspaceCommand(
                .run(target: product, arguments: projectSettings?.run.arguments ?? []),
                statusTitle: product.map { "Run \($0) on macOS" } ?? "Run on macOS"
            )
        case .web:
            guard let product else {
                workspaceStatus = .failed("Select an executable product before running for Web.")
                return
            }
            executeWorkspaceCommand(
                .runWeb(target: product, outputPath: "dist/web", serve: true),
                statusTitle: "Run \(product) on Web · http://127.0.0.1:8080"
            )
        case .iPadOS:
            guard
                let projectURL,
                let settings = try? ProjectSystem.loadProject(at: projectURL, fileManager: fileManager)
            else {
                workspaceStatus = .failed("Unable to load project settings for iPadOS.")
                return
            }
            do {
                try ProjectSystem.validateRunCompatibility(of: settings, at: projectURL, destination: .iPadOS, fileManager: fileManager)
            } catch {
                workspaceStatus = .failed(error.message)
                footer.setWorkspaceFooterTitle(workspaceStatus.title)
                appendOutput(error.message)
            }
        }
    }

    func buildAdaScriptProject(
        _ settings: AdaProject,
        at projectURL: URL,
        statusTitle: String,
        onSuccess: @escaping @MainActor (EditorAdaScriptProjectBuildArtifact) -> Void = { _ in }
    ) {
        guard workspaceTask == nil else {
            return
        }
        let notificationRunID = beginWorkspaceActivity(title: statusTitle, source: .build, supportsCancellation: false)
        workspaceStatus = .running(statusTitle)
        buildActivity = EditorBuildActivity(title: statusTitle)
        footer.setWorkspaceFooterTitle(workspaceStatus.title)
        appendOutput("Compiling AdaScript sources (SwiftPM disabled)...")
        let destination = selectedRunDestination.adaProjectDestination
        workspaceTask = Task { [weak self] in
            let outcome =
                await Task.detached(priority: .userInitiated) {
                    Self.prepareAdaScriptProject(
                        settings,
                        at: projectURL,
                        destination: destination
                    )
                }
                .value
            guard !Task.isCancelled, let self else {
                return
            }
            self.workspaceTask = nil
            switch outcome {
            case let .success(artifact):
                self.finishWorkspaceActivity(notificationRunID, succeeded: true)
                self.finishAdaScriptProjectBuild(artifact)
                onSuccess(artifact)
            case let .projectFailure(error):
                self.finishAdaScriptProjectBuildFailure(message: error.message)
                self.finishWorkspaceActivity(notificationRunID, succeeded: false, detail: error.message)
            case let .adaScriptFailure(error):
                let message = error.errorDescription ?? error.localizedDescription
                self.finishAdaScriptProjectBuildFailure(message: message)
                self.finishWorkspaceActivity(
                    notificationRunID,
                    succeeded: false,
                    detail: message,
                    action: Self.notificationAction(for: error, projectID: self.project?.id)
                )
            case let .failure(message):
                self.finishAdaScriptProjectBuildFailure(message: message)
                self.finishWorkspaceActivity(notificationRunID, succeeded: false, detail: message)
            }
        }
    }

    nonisolated private static func prepareAdaScriptProject(
        _ settings: AdaProject,
        at projectURL: URL,
        destination: AdaProjectRunDestination
    ) -> EditorAdaScriptProjectBuildOutcome {
        let fileManager = FileManager()
        do {
            try ProjectSystem.validateRunCompatibility(
                of: settings,
                at: projectURL,
                destination: destination,
                fileManager: fileManager
            )
            return .success(
                try EditorAdaScriptProjectBuilder(fileManager: fileManager)
                    .prepare(
                        project: settings,
                        at: projectURL
                    )
            )
        } catch let error as ProjectSystemError {
            return .projectFailure(error)
        } catch let error as EditorAdaScriptProjectBuildError {
            return .adaScriptFailure(error)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func notificationAction(
        for error: EditorAdaScriptProjectBuildError,
        projectID: String?
    ) -> EditorNotificationAction? {
        switch error {
        case .entryViewMissing:
            EditorNotificationAction(
                title: "Open Runtime Entry",
                destination: .projectSettings,
                projectID: projectID,
                settingsPage: EditorSettingsPage.runtimeEntry
            )
        default:
            nil
        }
    }

    func finishAdaScriptProjectBuild(_ artifact: EditorAdaScriptProjectBuildArtifact) {
        let report = artifact.report
        packageModel = nil
        workspaceStatus = .ready
        footer.setWorkspaceFooterTitle(workspaceStatus.title)
        buildActivity?.finish(succeeded: true)
        appendOutput(
            "AdaScript build succeeded: \(report.sourceCount) source(s), \(report.systemCount) system(s), \(report.viewCount) view(s), entry \(report.entryDescription)."
        )
        appendOutput("Runtime plugins: \(report.pluginIDs.joined(separator: ", "))")
        refreshPreviewForActiveDocument()
    }

    func finishAdaScriptProjectBuildFailure(message: String) {
        workspaceStatus = .failed(message)
        footer.setWorkspaceFooterTitle(workspaceStatus.title)
        buildActivity?.finish(succeeded: false)
        appendOutput(message)
    }

    @discardableResult
    func launchAdaScriptProject(
        _ artifact: EditorAdaScriptProjectBuildArtifact,
        projectName: String
    ) -> Bool {
        do {
            let runtimeView = try EditorAdaScriptProjectRuntimeView(artifact: artifact)
            let windowManager = try requireWindowManager()
            adaScriptRuntimeWindow?.close()
            let windowSettings = artifact.window
            let width = Float(windowSettings.size.width)
            let height = Float(windowSettings.size.height)
            let windowTitle = windowSettings.title.flatMap { $0.isEmpty ? nil : $0 } ?? projectName
            let configuration = UIWindow.Configuration(
                title: windowTitle,
                frame: Rect(x: 0, y: 0, width: width, height: height),
                minimumSize: Size(width: min(640, width), height: min(420, height)),
                mode: .windowed,
                showsImmediately: false,
                makeKey: true,
                isResizable: windowSettings.isResizable,
                scenePresentation: .new
            )
            let window = windowManager.spawnWindow(configuration: configuration) {
                runtimeView
            }
            window.onDidDisappear = { [weak self, weak window, performanceSession = runtimeView.performanceSession] in
                performanceSession.stop()
                guard let self, self.adaScriptRuntimeWindow === window else {
                    return
                }
                self.adaScriptRuntimeWindow = nil
                self.workspaceStatus = .ready
                self.footer.setWorkspaceFooterTitle(self.workspaceStatus.title)
                self.appendOutput("AdaScript project \(windowTitle) stopped.")
                if self.debugger.status.hasPrefix("AdaScript runtime is running") {
                    self.debugger.status = "AdaScript debug run stopped."
                }
            }
            window.showWindow(makeFocused: true)
            adaScriptRuntimeWindow = window
            workspaceStatus = .running("Run \(windowTitle)")
            footer.setWorkspaceFooterTitle(workspaceStatus.title)
            appendOutput("Running AdaScript project \(windowTitle) in a separate window scene.")
            return true
        } catch {
            workspaceStatus = .failed(error.localizedDescription)
            footer.setWorkspaceFooterTitle(workspaceStatus.title)
            appendOutput("AdaScript launch failed: \(error.localizedDescription)")
            return false
        }
    }

    func requireWindowManager() throws -> UIWindowManager {
        guard let windowManager = UIWindowManager.shared else {
            throw EditorAdaScriptRuntimeError.windowManagerUnavailable
        }
        return windowManager
    }

    var isProjectRunning: Bool {
        if playerSession.isRunning || playerSession.isBusy {
            return true
        }
        if debugger.isActive {
            return true
        }
        if case .running = workspaceStatus {
            return true
        }
        return false
    }

    var activeActivities: [EditorActivityEvent] {
        EditorActivityPresentation.events(
            workspaceStatus: workspaceStatus,
            buildActivity: buildActivity,
            previewStatus: workbench.previewStatus,
            sourceControlIsRunning: sourceControl.isRunning,
            sourceControlTitle: sourceControl.statusMessage
        )
            + EditorNotificationCenter.shared.activities.active.filter { $0.source == .agent }
            .map {
                EditorActivityEvent(
                    id: $0.id,
                    kind: .agent,
                    title: $0.title,
                    detail: $0.detail,
                    fractionCompleted: $0.fractionCompleted.map { Float($0) }
                )
            }
    }

    func runActiveSceneInEditor() {
        guard !debugger.isActive else {
            return
        }
        guard !playModeState.isPlaying else {
            return
        }
        reloadScriptableObjectSupport()

        guard let document = sceneDocumentForPlay() else {
            return
        }

        guard EditorSceneFileLoader.model(from: document.content) != nil else {
            failPlayMode("Unable to play \(document.title): scene document is invalid.")
            return
        }

        workbench.open(.scene(document))
        toolbar.sceneName = URL(fileURLWithPath: document.title).deletingPathExtension().lastPathComponent
        playModeState = .playing(sceneDocumentID: document.id, title: document.title)
        workspaceStatus = .running("Play \(document.title)")
        appendOutput("Playing \(document.relativePath)")
    }

    func runFromToolbar() {
        runSelectedTarget()
    }

    func stopFromToolbar() {
        if selectedRunDestination == .player, playerSession.isRunning || playerSession.isBusy {
            playerSession.stop()
            return
        }
        if playModeState.isPlaying {
            stopPlayMode()
        } else {
            cancelWorkspaceCommand()
        }
    }

    func presentSceneInspector() {
        toolStrip.activeRightTool = "inspector"
        showRightPanel = true
    }

    func stopPlayMode() {
        guard playModeState.isPlaying else {
            return
        }

        playModeState = .editing
        workspaceStatus = .ready
        appendOutput("Stopped Play Mode")
    }

    func runTests(filter: String? = nil) {
        executeWorkspaceCommand(
            .test(filter: filter ?? (selectedTestFilter.isEmpty ? nil : selectedTestFilter)),
            statusTitle: "Test"
        )
    }

    func updateDependencies() {
        executeWorkspaceCommand(.update, statusTitle: "Update Dependencies")
    }

    func cleanPackageCache() {
        executeWorkspaceCommand(.clean, statusTitle: "Clean")
    }

    func resetPackageCache() {
        executeWorkspaceCommand(.reset, statusTitle: "Reset")
    }

    func cancelWorkspaceCommand() {
        if playerSession.isRunning || playerSession.isBusy {
            playerSession.stop()
            return
        }
        if debugger.isActive {
            debugger.stop()
            return
        }
        if playModeState.isPlaying {
            stopPlayMode()
            return
        }
        if let adaScriptRuntimeWindow {
            adaScriptRuntimeWindow.close()
            self.adaScriptRuntimeWindow = nil
            workspaceStatus = .ready
            footer.setWorkspaceFooterTitle(workspaceStatus.title)
            appendOutput("Stopped AdaScript project.")
            return
        }
        workspaceTask?.cancel()
        workspaceTask = nil
        workspaceStatus = .cancelled
        Task {
            await workspaceService.cancel()
        }
    }

    @discardableResult
    func handleMenuCommand(_ command: EditorMenuCommand) -> Bool {
        switch command {
        case .checkForUpdates:
            EditorUpdateCenter.shared.checkForUpdates()
        case .showSettings:
            presentSettings(.general)
        case .debugOverlayOff:
            showsDebugOverlay = nil
        case .debugOverlayRedraw:
            toggleDebugOverlay(.redraw)
        case .debugOverlayLayoutBounds:
            toggleDebugOverlay(.layoutBounds)
        case .debugOverlayHitTestTarget:
            toggleDebugOverlay(.hitTestTarget)
        case .debugOverlayFocusedNode:
            toggleDebugOverlay(.focusedNode)
        case .newFile:
            presentNewFileDialog()
        case .newProject:
            ProjectEditorLauncher.openWelcome(beginCreatingProject: true)
        case .openProject:
            openProjectFromMenu()
        case .importAssets:
            importAssets()
        case .save:
            saveActiveDocument()
        case .saveAll:
            if workbench.saveAllDocuments() {
                refreshSourceControl()
                reloadScriptableObjectSupport()
            }
        case .findInFile:
            guard workbench.presentFileSearch() else {
                return false
            }
            Task { @MainActor in
                await Task.yield()
                _ = EditorSearchShortcutMonitor.shared.focusSearchField(identifier: EditorCodeFileView.fileSearchFieldIdentifier)
            }
        case .findInProject:
            presentTextSearch()
        case .navigateBack:
            navigateBack()
        case .navigateForward:
            navigateForward()
        case .showProjectNavigator:
            toolStrip.activeLeftTopTool = "fileTree"
            showLeftPanel = true
        case .showInspector:
            toolStrip.activeRightTool = "inspector"
            showRightPanel = true
        case .showBuildOutput:
            showBuildOutput()
        case .showProblems:
            showBottomPanel = true
            selectOutputTab("Problems")
        case .refreshProjectFiles:
            refreshProjectFiles()
        case .revealProject:
            if let projectURL {
                _ = EditorPlatformFileActions.reveal(projectURL)
            }
        case .openProjectInTerminal:
            if let projectURL {
                _ = EditorPlatformFileActions.openInTerminal(projectURL)
            }
        case .showProjectSettings:
            presentSettings(.project)
        case .showProjectDependencies:
            toolStrip.activeRightTool = "projectDependencies"
            showRightPanel = true
        case .showPackageTasks:
            toolStrip.activeRightTool = "swiftPackageTasks"
            showRightPanel = true
        case .build:
            buildAll()
        case .run:
            if workbench.activeSceneDocument != nil {
                runActiveSceneInEditor()
            } else {
                runSelectedTarget()
            }
        case .runTests:
            runTests()
        case .stop:
            cancelWorkspaceCommand()
        case .clean:
            cleanPackageCache()
        case .updateDependencies:
            updateDependencies()
        case .showPreview:
            showPreview()
        case .rebuildPreview:
            rebuildSelectedPreview()
        case .closeEditorTab:
            workbench.closeDocument(id: workbench.activeDocumentID)
        case .closeAllEditorTabs:
            workbench.closeAllDocuments()
        case .increaseCodeFontSize:
            workbench.increaseCodeFontSize()
        case .decreaseCodeFontSize:
            workbench.decreaseCodeFontSize()
        case .resetCodeFontSize:
            workbench.resetCodeFontSize()
        case .undo:
            return workbench.performDocumentHistory(redo: false)
        case .redo:
            return workbench.performDocumentHistory(redo: true)
        case .closeEditor,
            .cut,
            .copy,
            .paste,
            .selectAll,
            .enterFullScreen,
            .minimizeWindow,
            .zoomWindow,
            .bringAllToFront,
            .showDocumentation,
            .showSourceRepository:
            return false
        }
        return true
    }
}
