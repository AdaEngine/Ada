@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

extension EditorViewModel {
    func handleTextSelection(document: EditorTextDocument, range: EditorSourceRange?, text: String?) {
        workbench.updateTextDocument(id: document.id) { updatedDocument in
            updatedDocument.selectionRange = range
            updatedDocument.selectedText = text?.isEmpty == false ? text : nil
        }
    }

    func chatAboutTextSelection(document: EditorTextDocument, range: EditorSourceRange, text: String) {
        guard !text.isEmpty else {
            return
        }
        handleTextSelection(document: document, range: range, text: text)
        agent.prefillCodeSelection(
            EditorAgentCodeSelectionContext(
                documentTitle: document.title,
                documentRelativePath: document.relativePath,
                language: document.language.rawValue,
                range: range,
                text: text
            )
        )
        toolStrip.activeRightTool = "agentChat"
        showRightPanel = true
    }

    func openProjectFromMenu() {
        guard workbench.saveAllDocuments() else {
            return
        }
        ProjectOpenPicker.presentProjectPicker { [weak self] url in
            guard let self, let url else {
                return
            }
            do {
                let project = try EditorProjectStore(fileManager: self.fileManager).openProject(at: url)
                ProjectEditorLauncher.openEditor(for: project)
            } catch {
                self.workspaceStatus = .failed("Unable to open project: \(error.localizedDescription)")
                self.footer.setWorkspaceFooterTitle(self.workspaceStatus.title)
            }
        }
    }

    func refreshProjectFiles(logsRefresh: Bool = true) {
        let selectedID = projectSidebar.selectedItem?.id
        let collapsedIDs = projectSidebar.collapsedFolderIDs
        let items = Self.projectTreeItems(for: project, fileManager: fileManager)
        projectSidebar.items = items
        projectSidebar.collapsedFolderIDs = collapsedIDs.intersection(Set(items.lazy.filter(\.isFolder).map(\.id)))
        if let selected = items.first(where: { $0.id == selectedID }) {
            projectSidebar.select(selected)
        }
        toolbar.searchableItems = items
        syncInspectorTextureAssets()
        reloadScriptableObjectSupport()
        if logsRefresh {
            appendOutput("Refreshed project files")
        }
    }

    func selectWorkbenchDocument(id documentID: String) {
        workbench.selectDocument(id: documentID)
        refreshPreviewForActiveDocument()
    }

    func navigateBack() {
        if workbench.navigateBack() {
            refreshPreviewForActiveDocument()
        }
    }

    func navigateForward() {
        if workbench.navigateForward() {
            refreshPreviewForActiveDocument()
        }
    }

    func saveActiveDocument() {
        if workbench.saveActiveDocument() {
            refreshSourceControl()
            refreshPreviewForActiveDocument()
            reloadScriptableObjectSupport()
        }
    }

    @discardableResult
    func saveActiveDocumentIfNeeded() -> Bool {
        guard workbench.activeDocument?.isDirty == true else {
            return true
        }
        if workbench.saveActiveDocumentIfNeeded() {
            refreshSourceControl()
            reloadScriptableObjectSupport()
            return true
        }
        return false
    }

    func reloadScriptableObjectSupport() {
        guard
            let projectURL,
            let settings = try? ProjectSystem.loadProject(at: projectURL, fileManager: fileManager),
            settings.build.system.isAdaScript,
            let support = try? EditorScriptableObjectCatalogLoader.load(
                project: settings,
                at: projectURL,
                fileManager: fileManager
            )
        else {
            return
        }
        inspectorSidebar.scriptableObjectCatalog = support.descriptors
        scenePlayRuntime = support.playRuntime
    }

    func synchronizeAgentSceneContext() {
        guard case let .scene(document)? = workbench.activeDocument else {
            agent.setSceneContext(nil)
            return
        }

        agent.setSceneContext(EditorAgentSceneContext(document: document))
    }

    func selectPreview(_ declaration: EditorPreviewDeclaration) {
        workbench.isPreviewEnabled = true
        workbench.selectedPreviewID = declaration.id
        buildPreview(declaration)
    }

    func rebuildSelectedPreview() {
        workbench.isPreviewEnabled = true
        guard let document = activePreviewTextDocument() else {
            workbench.previewStatus = .hidden
            return
        }

        let declarations = EditorPreviewScanner.declarations(in: document.content, language: document.language)
        guard !declarations.isEmpty else {
            workbench.previewStatus = .hidden
            return
        }

        let selected = declarations.first { $0.id == workbench.selectedPreviewID } ?? declarations[0]
        workbench.selectedPreviewID = selected.id
        buildPreview(selected)
    }

    func showPreview() {
        workbench.isPreviewEnabled = true
        refreshPreviewForActiveDocument()
    }

    func hidePreview() {
        workbench.isPreviewEnabled = false
        workbench.previewStatus = .hidden
        workbench.loadedPreview = nil
        cancelPreviewBuild()
    }

    func refreshPreviewForActiveDocument() {
        guard workbench.isPreviewEnabled else {
            workbench.previewStatus = .hidden
            cancelPreviewBuild()
            return
        }
        guard let document = activePreviewTextDocument() else {
            workbench.previewStatus = .hidden
            workbench.selectedPreviewID = nil
            workbench.loadedPreview = nil
            cancelPreviewBuild()
            return
        }

        let declarations = EditorPreviewScanner.declarations(in: document.content, language: document.language)
        guard !declarations.isEmpty else {
            if let loadedPreview = workbench.loadedPreview,
                loadedPreview.documentID == document.id {
                workbench.selectedPreviewID = loadedPreview.declaration.id
                buildPreview(loadedPreview.declaration)
                return
            }
            workbench.previewStatus = .hidden
            workbench.selectedPreviewID = nil
            workbench.loadedPreview = nil
            cancelPreviewBuild()
            return
        }

        let selected = declarations.first { $0.id == workbench.selectedPreviewID } ?? declarations[0]
        workbench.selectedPreviewID = selected.id
        if workbench.loadedPreview?.matches(documentID: document.id, previewID: selected.id) != true {
            workbench.loadedPreview = nil
        }

        guard selected.kind == .adaScript || packageModel != nil else {
            workbench.previewStatus = .unavailable("Resolve the SwiftPM workspace before building previews.")
            return
        }

        workbench.previewStatus = .available(declarations)
        buildPreview(selected)
    }

    func sceneDocumentForPlay() -> EditorSceneDocument? {
        if let activeScene = workbench.activeSceneDocument {
            return activeScene
        }

        return startupSceneDocumentForPlay()
    }

    func startupSceneDocumentForPlay() -> EditorSceneDocument? {
        guard let projectURL else {
            failPlayMode("No project is open and the active document is not a scene.")
            return nil
        }

        let projectMetadata: AdaProject
        do {
            projectMetadata = try ProjectSystem.loadProject(at: projectURL, fileManager: fileManager)
        } catch {
            failPlayMode("Unable to load \(ProjectSystem.metadataFileName): \(error.message)")
            return nil
        }

        guard let startupScene = projectMetadata.editor.startupScene, !startupScene.isEmpty else {
            failPlayMode("No active scene and \(ProjectSystem.metadataFileName) does not define editor.startupScene.")
            return nil
        }

        if case let .scene(openDocument)? = workbench.openDocuments.first(where: { document in
            guard case let .scene(sceneDocument) = document else {
                return false
            }
            return sceneDocument.relativePath == startupScene && (sceneDocument.absolutePath != nil || sceneDocument.isDirty)
        }) {
            return openDocument
        }

        let sceneURL = projectURL.appendingPathComponent(startupScene, isDirectory: false)
        guard fileManager.fileExists(atPath: sceneURL.path) else {
            failPlayMode("Startup scene not found: \(startupScene)")
            return nil
        }

        let content: String
        do {
            content = try String(contentsOf: sceneURL, encoding: .utf8)
        } catch {
            failPlayMode("Unable to read startup scene \(startupScene): \(error.localizedDescription)")
            return nil
        }

        let document = EditorSceneDocument(
            id: "scene:\(startupScene)",
            title: sceneURL.lastPathComponent,
            relativePath: startupScene,
            absolutePath: sceneURL.path,
            content: content,
            lastSavedContent: content,
            isReadOnly: Self.isSymbolicLink(at: sceneURL),
            sceneModel: EditorSceneFileLoader.model(from: content),
            errorMessage: nil,
            isDirty: false,
            statusMessage: Self.isSymbolicLink(at: sceneURL) ? "Read-only: symbolic link" : "Loaded",
            loadSummary: EditorSceneFileLoader.summary(from: content)
        )
        return document
    }

    func failPlayMode(_ message: String) {
        playModeState = .failed(message)
        workspaceStatus = .failed(message)
        appendOutput("Play failed: \(message)")
    }

    func toggleDebugOverlay(_ type: UIDebugOverlayMode) {
        if showsDebugOverlay == type {
            showsDebugOverlay = nil
        } else {
            showsDebugOverlay = type
        }
    }

    func activateLeftTopTool(_ item: EditorToolStripItem) {
        if toolStrip.activeLeftTopTool == item.identifier && showLeftPanel {
            showLeftPanel = false
            return
        }

        toolStrip.selectLeftTopTool(item)
        showLeftPanel = true
    }

    func activateLeftBottomTool(_ item: EditorToolStripItem) {
        if item.identifier == "logs", activeOutputTab != "Output" {
            toolStrip.selectLeftBottomTool(item)
            selectOutputTab("Output")
            showBottomPanel = true
            return
        }
        if toolStrip.activeLeftBottomTool == item.identifier && showBottomPanel {
            showBottomPanel = false
            return
        }

        toolStrip.selectLeftBottomTool(item)
        if item.identifier == "logs" {
            selectOutputTab("Output")
        }
        if item.identifier == "build" {
            selectOutputTab("Build")
        }
        showBottomPanel = true
    }

    func activateRightTool(_ item: EditorToolStripItem) {
        switch item.identifier {
        case "projectSettings":
            presentSettings(.project)
            return
        default:
            break
        }

        if toolStrip.activeRightTool == item.identifier && showRightPanel {
            showRightPanel = false
            return
        }

        toolStrip.selectRightTool(item)
        showRightPanel = true
    }

    func presentSettings(_ section: EditorSettingsSection, page: String? = nil) {
        requestedSettingsSection = section
        requestedSettingsPage = page
        settingsPresentationToken += 1
        showRightPanel = false
    }

    var settingsPresentationBinding: Binding<EditorSettingsSection?> {
        Binding(
            get: { self.requestedSettingsSection },
            set: {
                self.requestedSettingsSection = $0
                if $0 == nil {
                    self.requestedSettingsPage = nil
                }
            }
        )
    }

    func isLeftTopToolPresented(_ item: EditorToolStripItem) -> Bool {
        toolStrip.activeLeftTopTool == item.identifier && showLeftPanel
    }

    func isLeftBottomToolPresented(_ item: EditorToolStripItem) -> Bool {
        toolStrip.activeLeftBottomTool == item.identifier && showBottomPanel
    }

    func isRightToolPresented(_ item: EditorToolStripItem) -> Bool {
        toolStrip.activeRightTool == item.identifier && showRightPanel
    }

    func selectOutputTab(_ tab: String) {
        if tab == "Debug" {
            presentDebugger()
            return
        }
        activeOutputTab = tab
        workbench.activeOutputTab = tab
    }

    func clearOutput() {
        outputLines.removeAll()
        pendingWorkspaceStandardOutput = ""
        pendingWorkspaceStandardError = ""
    }

    func showBuildOutput() {
        showBottomPanel = true
        toolStrip.activeLeftBottomTool = "build"
        selectOutputTab("Build")
    }
}
