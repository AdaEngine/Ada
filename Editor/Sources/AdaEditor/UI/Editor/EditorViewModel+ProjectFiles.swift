@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

extension EditorViewModel {
    func openProjectItem(_ item: EditorProjectSidebarViewModel.Item) {
        if item.isFolder {
            projectSidebar.select(item)
            projectSidebar.toggleFolder(item)
            return
        }

        projectSidebar.select(item)
        let document = Self.document(for: item)
        workbench.open(document)
        if case let .asset(asset) = document, asset.kind == .tileSource {
            presentSceneInspector()
        }
        if case .ui = document {
            refreshUIExports()
        }
        refreshSemanticTokens(for: document)
        refreshPreviewForActiveDocument()

        if case .scene = document {
            toolbar.sceneName = URL(fileURLWithPath: item.title).deletingPathExtension().lastPathComponent
        }
    }

    func openSearchResult(_ item: EditorProjectSidebarViewModel.Item) {
        guard let currentItem = projectSidebar.items.first(where: { $0.id == item.id }) else {
            return
        }
        toolbar.clearSearch()
        openProjectItem(currentItem)
    }

    func findInProjectFolder(_ item: EditorProjectSidebarViewModel.Item) {
        if item.isFolder {
            toolbar.search(in: item)
            return
        }

        let parentPath = URL(fileURLWithPath: item.relativePath, isDirectory: false)
            .deletingLastPathComponent()
            .relativePath
        toolbar.search(
            in: projectSidebar.items.first { candidate in
                candidate.isFolder && candidate.relativePath == parentPath
            }
        )
    }

    func findInProjectRoot() {
        toolbar.search(in: nil)
    }

    func revealProjectItem(_ item: EditorProjectSidebarViewModel.Item) {
        performPlatformFileAction(named: "Reveal in Finder", url: fileURL(for: item), action: EditorPlatformFileActions.reveal)
    }

    func openProjectItemInDefaultApplication(_ item: EditorProjectSidebarViewModel.Item) {
        performPlatformFileAction(named: "Open in Default App", url: fileURL(for: item), action: EditorPlatformFileActions.openInDefaultApplication)
    }

    func openProjectItemInTerminal(_ item: EditorProjectSidebarViewModel.Item) {
        performPlatformFileAction(named: "Open in Terminal", url: fileURL(for: item), action: EditorPlatformFileActions.openInTerminal)
    }

    func copyProjectItemPath(_ item: EditorProjectSidebarViewModel.Item, relative: Bool) {
        let value = relative ? item.relativePath : fileURL(for: item)?.path
        guard let value, EditorPlatformFileActions.copyToClipboard(value) else {
            appendOutput("Copy path is unavailable on this platform.")
            return
        }
        appendOutput("Copied \(relative ? "relative path" : "path"): \(value)")
    }

    func revealDocument(_ document: EditorWorkbenchDocument) {
        let url = document.absolutePath.map { URL(fileURLWithPath: $0, isDirectory: false) }
        performPlatformFileAction(named: "Reveal in Finder", url: url, action: EditorPlatformFileActions.reveal)
    }

    func copyDocumentPath(_ document: EditorWorkbenchDocument, relative: Bool) {
        let value = relative ? document.relativePath : document.absolutePath
        guard let value, EditorPlatformFileActions.copyToClipboard(value) else {
            appendOutput("Copy path is unavailable on this platform.")
            return
        }
        appendOutput("Copied \(relative ? "relative path" : "path"): \(value)")
    }

    func fileURL(for item: EditorProjectSidebarViewModel.Item) -> URL? {
        Self.absoluteFilePath(from: item.id)
            .map {
                URL(fileURLWithPath: $0, isDirectory: item.isFolder)
            }
    }

    func performPlatformFileAction(
        named actionName: String,
        url: URL?,
        action: (URL) -> Bool
    ) {
        guard let url, action(url) else {
            appendOutput("\(actionName) is unavailable on this platform.")
            return
        }
        appendOutput("\(actionName): \(relativeProjectPath(for: url.path))")
    }

    @MainActor
    func importAssets() {
        guard let urls = ProjectOpenPicker.pickAssetImportURLs(), !urls.isEmpty else {
            return
        }

        importAssets(from: urls)
    }

    func importAssets(from sourceURLs: [URL]) {
        guard let projectURL else {
            appendOutput("Asset import failed: no project is open.")
            return
        }

        let assetsURL = Self.assetsDirectoryURL(for: projectURL, fileManager: fileManager)
        do {
            try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
            for sourceURL in sourceURLs {
                let destinationURL = uniqueAssetDestinationURL(for: sourceURL, in: assetsURL)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                appendOutput("Imported asset \(sourceURL.lastPathComponent) -> \(relativeProjectPath(for: destinationURL.path))")
            }
            try ensureAssetResourcesInManifest(projectURL: projectURL)
            if !sourceURLs.isEmpty {
                workbench.achievements?.record([.firstImport: 1])
            }
            projectSidebar.items = Self.projectTreeItems(for: project, fileManager: fileManager)
            toolbar.searchableItems = projectSidebar.items
            syncInspectorTextureAssets()
            refreshSourceControl()
        } catch {
            appendOutput("Asset import failed: \(error.localizedDescription)")
            workspaceStatus = .failed(error.localizedDescription)
        }
    }

    func uniqueAssetDestinationURL(for sourceURL: URL, in assetsURL: URL) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension
        var candidate = assetsURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
        var counter = 2

        while fileManager.fileExists(atPath: candidate.path) {
            let name = pathExtension.isEmpty ? "\(baseName)-\(counter)" : "\(baseName)-\(counter).\(pathExtension)"
            candidate = assetsURL.appendingPathComponent(name, isDirectory: false)
            counter += 1
        }

        return candidate
    }

    func ensureAssetResourcesInManifest(projectURL: URL) throws {
        let manifestURL = projectURL.appendingPathComponent("Package.swift", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return
        }

        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let result = try PackageManifestEditor.edit(
            manifest,
            command: .ensureAssetResources(targetName: selectedRunTargetName, assetsPath: "Assets")
        )
        guard result.changed else {
            return
        }

        try result.manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        appendOutput("Updated Package.swift to copy Assets into the executable bundle.")
    }

    func openProjectItemAsRaw(_ item: EditorProjectSidebarViewModel.Item) {
        guard !item.isFolder else {
            return
        }

        projectSidebar.select(item)
        let content = Self.textFileContent(for: item)
        workbench.open(
            .text(
                EditorTextDocument(
                    id: "raw:\(item.relativePath)",
                    title: "\(item.title) Raw",
                    relativePath: item.relativePath,
                    absolutePath: Self.absoluteFilePath(from: item.id),
                    language: .yaml,
                    content: content.value,
                    lastSavedContent: content.errorMessage == nil ? content.value : nil,
                    isReadOnly: item.isSymbolicLink || content.errorMessage != nil,
                    errorMessage: content.errorMessage,
                    statusMessage: item.isSymbolicLink ? "Read-only: symbolic link" : content.errorMessage == nil ? nil : "Read-only: unable to read as UTF-8"
                )
            )
        )
        if let document = workbench.activeDocument {
            refreshSemanticTokens(for: document)
        }
    }

    func handleAgentProjectFileChanged(relativePath: String, fileManager _: FileManager = .default) {
        refreshProjectFiles(logsRefresh: false)
        refreshSourceControl()
        reloadOpenProjectFile(relativePath: relativePath)
    }

    func reloadOpenProjectFile(relativePath: String) {
        guard let projectURL else {
            return
        }

        let changedURL = projectURL.appendingPathComponent(relativePath).standardizedFileURL
        EventManager.default.send(UISceneResourceChanged(url: changedURL))
        if relativePath == ".ada/ui-exports.json" {
            refreshUIExports()
        }
        for document in workbench.openDocuments {
            guard document.relativePath == relativePath else {
                continue
            }

            switch document {
            case let .text(textDocument),
                let .ui(textDocument):
                guard !textDocument.isDirty else {
                    continue
                }
                do {
                    let content = try String(contentsOf: changedURL, encoding: .utf8)
                    workbench.uiSceneModels[textDocument.id]?.reload(content: content)
                    workbench.updateTextDocument(id: textDocument.id) { updatedDocument in
                        updatedDocument.content = content
                        updatedDocument.lastSavedContent = content
                        updatedDocument.isReadOnly = Self.isSymbolicLink(at: changedURL)
                        updatedDocument.errorMessage = nil
                        updatedDocument.statusMessage = updatedDocument.isReadOnly ? "Read-only: symbolic link" : "Reloaded"
                    }
                } catch {
                    workbench.updateTextDocument(id: textDocument.id) { updatedDocument in
                        updatedDocument.isReadOnly = true
                        updatedDocument.errorMessage = error.localizedDescription
                        updatedDocument.statusMessage = "Read-only: unable to read as UTF-8"
                    }
                }
            case var .scene(sceneDocument):
                guard !sceneDocument.isDirty else {
                    continue
                }
                do {
                    sceneDocument.content = try String(contentsOf: changedURL, encoding: .utf8)
                    sceneDocument.lastSavedContent = sceneDocument.content
                    sceneDocument.sceneModel = EditorSceneFileLoader.model(from: sceneDocument.content)
                    sceneDocument.loadSummary = EditorSceneFileLoader.summary(from: sceneDocument.content)
                    sceneDocument.statusMessage = "Reloaded"
                    sceneDocument.errorMessage = nil
                    workbench.replaceSceneDocument(sceneDocument)
                } catch {
                    sceneDocument.errorMessage = error.localizedDescription
                    sceneDocument.statusMessage = "Reload failed"
                    workbench.replaceSceneDocument(sceneDocument)
                }
            case .asset,
                .git:
                continue
            }
        }
    }
}
