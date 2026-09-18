@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

extension EditorViewModel {
    func activePreviewTextDocument() -> EditorTextDocument? {
        guard
            case let .text(document)? = workbench.activeDocument,
            document.language == .ada || document.language == .swift || document.language == .packageManifest
        else {
            return nil
        }

        return document
    }

    func buildPreview(_ declaration: EditorPreviewDeclaration) {
        guard let projectURL, let document = activePreviewTextDocument() else {
            workbench.previewStatus = .unavailable("Preview requires an open project.")
            return
        }
        if workbench.loadedPreview?.matches(documentID: document.id, previewID: declaration.id) != true {
            workbench.loadedPreview = nil
        }

        switch declaration.kind {
        case .adaScript:
            buildAdaScriptPreview(
                declaration,
                projectURL: projectURL,
                packageModel: packageModel,
                document: document
            )
        case .swift:
            guard let packageModel else {
                workbench.previewStatus = .unavailable("Resolve the SwiftPM workspace before building Swift previews.")
                return
            }
            buildSwiftPreview(
                declaration,
                projectURL: projectURL,
                packageModel: packageModel,
                document: document
            )
        }
    }

    func buildSwiftPreview(
        _ declaration: EditorPreviewDeclaration,
        projectURL: URL,
        packageModel: SwiftPackageModel,
        document: EditorTextDocument
    ) {
        let generation = beginPreviewBuild()
        workbench.previewStatus = .building(declaration, "Preparing preview build...")
        appendOutput("Building preview \(declaration.title) from \(document.relativePath)")

        let request = EditorPreviewBuildRequest(
            projectURL: projectURL,
            document: document,
            packageModel: packageModel,
            declaration: declaration
        )
        previewTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let artifact = try await self.previewBuilder.build(request)
                await MainActor.run {
                    guard
                        self.isCurrentPreviewBuild(
                            generation,
                            documentID: document.id,
                            previewID: declaration.id
                        )
                    else {
                        return
                    }

                    do {
                        self.appendOutputBlock(artifact.buildOutput)
                        let view = try self.previewLibrary.load(artifact: artifact)
                        self.workbench.loadedPreview = EditorLoadedPreview(
                            documentID: document.id,
                            declaration: declaration,
                            view: view
                        )
                        self.workbench.previewStatus = .loaded(declaration, view)
                        self.appendOutput("Loaded preview \(declaration.title)")
                    } catch {
                        self.workbench.previewStatus = .failed(
                            declaration,
                            self.previewFailureMessage(prefix: "Preview load failed", error: error),
                            true
                        )
                        self.appendOutput("Preview load failed:")
                        self.appendOutputBlock(String(describing: error))
                    }
                    self.previewTask = nil
                }
            } catch {
                await MainActor.run {
                    guard
                        self.isCurrentPreviewBuild(
                            generation,
                            documentID: document.id,
                            previewID: declaration.id
                        )
                    else {
                        return
                    }
                    self.workbench.previewStatus = .failed(
                        declaration,
                        self.previewFailureMessage(prefix: "Preview build failed", error: error),
                        true
                    )
                    self.appendOutput("Preview build failed:")
                    self.appendOutputBlock(String(describing: error))
                    self.previewTask = nil
                }
            }
        }
    }

    func buildAdaScriptPreview(
        _ declaration: EditorPreviewDeclaration,
        projectURL: URL,
        packageModel: SwiftPackageModel?,
        document: EditorTextDocument
    ) {
        let generation = beginPreviewBuild()
        workbench.previewStatus = .building(declaration, "Preparing AdaScript preview...")
        appendOutput("Building AdaScript preview \(declaration.title) from \(document.relativePath)")

        let request = EditorAdaScriptPreviewBuildRequest(
            projectURL: projectURL,
            document: document,
            packageModel: packageModel,
            declaration: declaration
        )
        previewTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let artifact = try await self.adaScriptPreviewBuilder.build(request)
                try Task.checkCancellation()
                let rootView = try AdaScriptView(
                    sources: artifact.sources,
                    identifier: artifact.identifier
                )
                let view = UIContainerView(rootView: rootView)

                guard
                    self.isCurrentPreviewBuild(
                        generation,
                        documentID: document.id,
                        previewID: declaration.id
                    )
                else {
                    return
                }
                self.workbench.loadedPreview = EditorLoadedPreview(
                    documentID: document.id,
                    declaration: declaration,
                    view: view
                )
                self.workbench.previewStatus = .loaded(declaration, view)
                self.appendOutput("Loaded AdaScript preview \(declaration.title)")
                self.previewTask = nil
            } catch is CancellationError {
                if generation == self.previewBuildGeneration {
                    self.previewTask = nil
                }
            } catch {
                guard
                    self.isCurrentPreviewBuild(
                        generation,
                        documentID: document.id,
                        previewID: declaration.id
                    )
                else {
                    return
                }
                self.workbench.previewStatus = .failed(
                    declaration,
                    self.previewFailureMessage(prefix: "AdaScript preview failed", error: error),
                    true
                )
                self.appendOutput("AdaScript preview failed:")
                self.appendOutputBlock(String(describing: error))
                self.previewTask = nil
            }
        }
    }

    func beginPreviewBuild() -> Int {
        previewTask?.cancel()
        previewBuildGeneration += 1
        return previewBuildGeneration
    }

    func cancelPreviewBuild() {
        previewTask?.cancel()
        previewTask = nil
        previewBuildGeneration += 1
    }

    func isCurrentPreviewBuild(_ generation: Int, documentID: String, previewID: String) -> Bool {
        guard
            generation == previewBuildGeneration,
            case let .text(activeDocument)? = workbench.activeDocument
        else {
            return false
        }
        return activeDocument.id == documentID && workbench.selectedPreviewID == previewID
    }

    func previewFailureMessage(prefix: String, error: any Error) -> String {
        let detail = String(describing: error)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let detail, !detail.isEmpty else {
            return "\(prefix). See Build Output for details."
        }
        let maximumDetailLength = 220
        let displayedDetail =
            detail.count > maximumDetailLength
            ? "\(detail.prefix(maximumDetailLength))…"
            : detail
        return "\(prefix): \(displayedDetail)"
    }

    func executeSourceControlCommand(
        _ kind: GitCommandKind,
        statusTitle: String,
        clearsCommitMessage: Bool = false,
        clearsNewBranchName: Bool = false
    ) {
        guard let projectURL else {
            sourceControl.statusMessage = "No project is open."
            footer.setSourceControlFooterTitle(nil)
            return
        }

        guard !sourceControl.isRunning else {
            return
        }
        sourceControl.refreshTask?.cancel()
        sourceControl.refreshGeneration = UUID()
        sourceControl.isRefreshing = false
        sourceControl.isRunning = true
        sourceControl.commandError = nil
        sourceControl.statusMessage = "Running \(statusTitle)..."
        appendOutput("$ \(statusTitle)")

        sourceControlTask = Task { [weak self] in
            guard let self else {
                return
            }
            let result = await self.sourceControlService.execute(kind, projectURL: projectURL)
            await MainActor.run {
                self.appendOutput(result)
                self.sourceControl.commandError = result.succeeded ? nil : result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.succeeded {
                    EditorNotificationCenter.shared.post(
                        .init(
                            source: .sourceControl,
                            importance: .error,
                            title: "\(statusTitle) failed",
                            detail: String(result.combinedOutput.prefix(600)),
                            projectName: self.project?.name,
                            actions: [.init(title: "Open Git", destination: .sourceControl, projectID: self.project?.id)]
                        )
                    )
                }
                self.sourceControl.statusMessage =
                    result.succeeded
                    ? "\(statusTitle) finished."
                    : result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                self.sourceControl.isRunning = false
                self.sourceControlTask = nil
                if result.succeeded {
                    if clearsCommitMessage {
                        self.sourceControl.commitMessage = ""
                    }
                    if clearsNewBranchName {
                        self.sourceControl.newBranchName = ""
                    }
                }
                self.refreshSourceControl()
            }
        }
    }

    func sourceControlStatusMessage(for result: GitRepositoryLoadResult) -> String {
        guard result.succeeded else {
            let statusOutput = result.statusResult.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !statusOutput.isEmpty {
                return statusOutput
            }

            let branchOutput = result.branchResult?.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return branchOutput.isEmpty ? "Source control unavailable." : branchOutput
        }

        if let message = result.snapshot.statusMessage, message != "Working tree clean" {
            return message
        }
        if result.snapshot.hasChanges {
            return "\(result.snapshot.files.count) changed file\(result.snapshot.files.count == 1 ? "" : "s")."
        }

        return result.snapshot.statusMessage ?? "Working tree clean."
    }

    func handleWorkspaceProgress(_ progress: SwiftPMWorkspaceProgress) {
        let phaseChanged = lastLoggedWorkspaceProgressPhase != progress.phase
        buildActivity?.consume(progress)
        switch progress.phase {
        case .ready:
            workspaceStatus = .ready
        case .failed:
            workspaceStatus = .failed(progress.detail ?? progress.title)
        case .resolvingDependencies:
            workspaceStatus = .resolving
        case .indexingBuild:
            workspaceStatus = .preparing(progress)
        default:
            workspaceStatus = .preparing(progress)
        }
        if progress.phase != .indexingBuild || phaseChanged {
            footer.setWorkspaceFooterTitle(workspaceStatus.title)
        }

        if phaseChanged {
            appendOutput("Workspace: \(progress.progressText)")
            if let detail = progress.detail, !detail.isEmpty {
                appendOutput(detail)
            }
            if let command = progress.command {
                appendOutput("$ \(command.shellDescription)")
            }
            lastLoggedWorkspaceProgressPhase = progress.phase
        } else if progress.phase == .indexingBuild, let detail = progress.detail, !detail.isEmpty {
            appendOutputBlock(detail)
        }
    }

    func executeWorkspaceCommand(_ kind: SwiftPMCommandKind, statusTitle: String) {
        guard workspaceTask == nil else {
            return
        }
        guard let projectURL else {
            workspaceStatus = .failed("No project is open.")
            return
        }
        if let settings = try? ProjectSystem.loadProject(at: projectURL, fileManager: fileManager) {
            if settings.build.system == .adaScript {
                let message = "SwiftPM commands are unavailable for AdaScript projects."
                workspaceStatus = .failed(message)
                footer.setWorkspaceFooterTitle(workspaceStatus.title)
                appendOutput(message)
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

        let source: EditorNotificationSource
        if case .test = kind {
            source = .test
        } else {
            source = .build
        }
        let notificationRunID = beginWorkspaceActivity(title: statusTitle, source: source)
        if case .run = kind {
            workspaceOutputIsGame = true
        } else {
            workspaceOutputIsGame = false
        }
        workspaceStatus = .running(statusTitle)
        buildActivity = EditorBuildActivity(title: statusTitle)
        pendingWorkspaceStandardOutput = ""
        pendingWorkspaceStandardError = ""
        didReceiveStreamingWorkspaceOutput = false
        appendOutput("$ \(statusTitle)")
        workspaceTask = Task { [weak self] in
            guard let self else {
                return
            }
            let result = await self.workspaceService.execute(kind, projectURL: projectURL) { [weak self] event in
                await MainActor.run {
                    self?.receiveWorkspaceOutput(event)
                }
            }
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                if EditorNotificationCenter.shared.activities.all.first(where: { $0.id == notificationRunID })?.state == .cancelled {
                    self.flushPendingWorkspaceOutput()
                    self.workspaceOutputIsGame = false
                    self.workspaceStatus = .ready
                    self.buildActivity = nil
                    self.notificationWorkspaceRunID = nil
                    self.workspaceTask = nil
                    return
                }
                if self.didReceiveStreamingWorkspaceOutput {
                    self.flushPendingWorkspaceOutput()
                    if self.workspaceOutputIsGame {
                        self.appendGameLog(["Exited with code \(result.exitCode)"])
                    } else {
                        self.appendOutput("Exited with code \(result.exitCode)")
                    }
                } else if self.workspaceOutputIsGame {
                    self.appendGameLog(result.combinedOutput.components(separatedBy: .newlines) + ["Exited with code \(result.exitCode)"])
                } else {
                    self.appendOutput(result)
                }
                self.workspaceOutputIsGame = false
                self.buildActivity?.finish(succeeded: result.succeeded)
                self.replaceBuildDiagnostics(with: EditorDiagnostic.diagnostics(from: result, projectURL: projectURL))
                self.showProblemsIfNeeded()
                self.workspaceStatus = result.succeeded ? .ready : .failed(result.combinedOutput)
                self.finishWorkspaceActivity(
                    notificationRunID,
                    succeeded: result.succeeded,
                    detail: result.succeeded ? "" : result.combinedOutput
                )
                self.workspaceTask = nil
            }
        }
    }

    func receiveWorkspaceOutput(_ event: EditorProcessOutputEvent) {
        didReceiveStreamingWorkspaceOutput = true
        switch event.stream {
        case .standardOutput:
            let update = Self.streamingOutput(event.text, pending: pendingWorkspaceStandardOutput)
            pendingWorkspaceStandardOutput = update.pending
            appendStreamingLines(update.lines)
        case .standardError:
            let update = Self.streamingOutput(event.text, pending: pendingWorkspaceStandardError)
            pendingWorkspaceStandardError = update.pending
            appendStreamingLines(update.lines)
        }
    }

    func appendStreamingLines(_ lines: [String]) {
        for line in lines {
            buildActivity?.consume(line)
        }
        if let id = notificationWorkspaceRunID, let step = buildActivity?.currentStep {
            let completed = step.fractionCompleted.map { Int64($0 * 1000) }
            EditorNotificationCenter.shared.activities.update(id, detail: step.title, completed: completed, total: completed == nil ? nil : 1000)
        }
        if workspaceOutputIsGame {
            appendGameLog(lines)
        } else {
            appendOutput(lines)
        }
    }

    static func streamingOutput(_ text: String, pending: String) -> (lines: [String], pending: String) {
        let combined = pending + text
        let lines = combined.components(separatedBy: .newlines)
        let endsWithNewline = combined.last?.isNewline == true
        let completeLineCount = endsWithNewline ? lines.count : max(0, lines.count - 1)
        return (
            lines: lines.prefix(completeLineCount).filter { !$0.isEmpty },
            pending: endsWithNewline ? "" : lines.last ?? ""
        )
    }

    func flushPendingWorkspaceOutput() {
        let pendingLines = [pendingWorkspaceStandardOutput, pendingWorkspaceStandardError].filter { !$0.isEmpty }
        for value in pendingLines {
            buildActivity?.consume(value)
        }
        if workspaceOutputIsGame {
            appendGameLog(pendingLines)
        } else {
            appendOutput(pendingLines)
        }
        pendingWorkspaceStandardOutput = ""
        pendingWorkspaceStandardError = ""
    }

    func appendOutput(_ result: EditorProcessResult) {
        var lines = ["$ \(result.command.shellDescription)"]
        let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            lines.append(contentsOf: output.components(separatedBy: .newlines))
        }
        lines.append("Exited with code \(result.exitCode)")
        appendOutput(lines)
    }

    func appendOutput(_ text: String) {
        appendOutput([text])
    }

    func appendOutput(_ lines: [String]) {
        outputLines = EditorWorkspaceLogBuffer.appending(lines, to: outputLines)
    }

    func appendOutputBlock(_ text: String) {
        let output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            return
        }

        appendOutput(output.components(separatedBy: .newlines))
    }

    func showProblemsIfNeeded() {
        guard !problems.isEmpty else {
            return
        }
        if !showBottomPanel {
            showBottomPanel = true
        }
        if activeOutputTab != "Problems" {
            selectOutputTab("Problems")
        }
    }
}
