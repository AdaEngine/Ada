@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

extension EditorViewModel {
    static func defaultWorkbench(for project: EditorProjectReference?) -> EditorWorkbenchViewModel {
        guard project != nil else {
            return EditorWorkbenchViewModel()
        }

        return EditorWorkbenchViewModel(activeEditorTab: "", openDocuments: [], activeDocumentID: "")
    }

    func scheduleAutosave(documentID: String) {
        autosaveTasks[documentID]?.cancel()
        let delay = autosaveDelay
        autosaveTasks[documentID] = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard let self else {
                return
            }
            self.autosaveTasks[documentID] = nil
            guard let document = self.workbench.openDocuments.first(where: { $0.id == documentID }), document.isDirty else {
                return
            }

            if self.workbench.saveDocument(document) {
                self.appendOutput("Autosaved \(document.relativePath)")
                if self.workbench.activeDocumentID == documentID {
                    self.refreshPreviewForActiveDocument()
                }
            }
        }
    }

    var projectURL: URL? {
        project.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    var projectAssetsURL: URL? {
        projectURL.map { Self.assetsDirectoryURL(for: $0, fileManager: fileManager) }
    }

    var projectRootSidebarItem: EditorProjectSidebarViewModel.Item? {
        guard let project, let projectURL else {
            return nil
        }

        return EditorProjectSidebarViewModel.Item(
            id: projectURL.path,
            disclosure: "",
            icon: "",
            title: project.name,
            relativePath: "",
            level: 0,
            isActive: false,
            isFolder: true,
            kind: .folder
        )
    }

    var newFileNameBinding: Binding<String> {
        Binding(
            get: { self.newFileName },
            set: {
                self.newFileName = $0
                self.newFileErrorMessage = nil
            }
        )
    }

    var isNewFileDialogPresentedBinding: Binding<Bool> {
        Binding(
            get: { self.isNewFileDialogPresented },
            set: { isPresented in
                self.isNewFileDialogPresented = isPresented
                if !isPresented {
                    self.newFileErrorMessage = nil
                }
            }
        )
    }

    var isDeleteProjectItemAlertPresentedBinding: Binding<Bool> {
        Binding(
            get: { self.pendingDeleteProjectItem != nil },
            set: { isPresented in
                if !isPresented {
                    self.pendingDeleteProjectItem = nil
                }
            }
        )
    }

    var newFileLocationTitle: String {
        newFileDestinationRelativePath.isEmpty ? (project?.name ?? "Project") : newFileDestinationRelativePath
    }

    var newFileExtensionHint: String {
        ".\(newFileKind.fileExtension)"
    }

    var newFilePreviewPath: String {
        let name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return ""
        }
        let fileName = URL(fileURLWithPath: name).pathExtension.isEmpty ? "\(name).\(newFileKind.fileExtension)" : name
        return newFileDestinationRelativePath.isEmpty ? fileName : "\(newFileDestinationRelativePath)/\(fileName)"
    }

    func presentNewFileDialog(kind: EditorNewFileKind? = nil) {
        guard projectURL != nil else {
            appendOutput("New file is unavailable: no project is open.")
            return
        }

        isNewFileKindPreselected = kind != nil
        if let kind {
            newFileKind = kind
        }

        let selectedItem = projectSidebar.selectedItem
        if let selectedItem {
            newFileDestinationRelativePath =
                selectedItem.isFolder
                ? selectedItem.relativePath
                : URL(fileURLWithPath: selectedItem.relativePath).deletingLastPathComponent().relativePath
            if newFileDestinationRelativePath == "." {
                newFileDestinationRelativePath = ""
            }
        } else {
            newFileDestinationRelativePath = ""
        }
        newFileName = ""
        newFileErrorMessage = nil
        isNewFileDialogPresented = true
    }

    func dismissNewFileDialog() {
        isNewFileDialogPresented = false
        newFileErrorMessage = nil
    }

    func presentDeleteProjectItemAlert(_ item: EditorProjectSidebarViewModel.Item) {
        guard fileURL(for: item) != nil else {
            appendOutput("Delete is unavailable for this item.")
            return
        }
        pendingDeleteProjectItem = item
    }

    @discardableResult
    func deleteProjectItem(_ item: EditorProjectSidebarViewModel.Item) -> Bool {
        pendingDeleteProjectItem = nil
        guard let projectURL, let itemURL = fileURL(for: item) else {
            appendOutput("Delete is unavailable for this item.")
            return false
        }

        let standardizedProjectURL = projectURL.standardizedFileURL
        let standardizedItemURL = itemURL.standardizedFileURL
        guard
            standardizedItemURL.path != standardizedProjectURL.path,
            standardizedItemURL.path.hasPrefix("\(standardizedProjectURL.path)/")
        else {
            appendOutput("Delete failed: the item is outside the project.")
            return false
        }

        do {
            try fileManager.removeItem(at: standardizedItemURL)
            workbench.discardDocuments(atOrBelow: item.relativePath)
            refreshProjectFiles(logsRefresh: false)
            refreshSourceControl()
            appendOutput("Deleted \(item.relativePath)")
            return true
        } catch {
            appendOutput("Delete failed for \(item.relativePath): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func createNewFile() -> Bool {
        guard let projectURL else {
            newFileErrorMessage = "No project is open."
            return false
        }

        let trimmedName = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            newFileErrorMessage = "Enter a file name."
            return false
        }
        guard
            trimmedName != ".", trimmedName != "..",
            !trimmedName.contains("/"), !trimmedName.contains("\\")
        else {
            newFileErrorMessage = "Enter a name without folders or path separators."
            return false
        }

        let enteredExtension = URL(fileURLWithPath: trimmedName, isDirectory: false).pathExtension
        guard enteredExtension.isEmpty || enteredExtension.caseInsensitiveCompare(newFileKind.fileExtension) == .orderedSame else {
            newFileErrorMessage = "\(newFileKind.title) files use the .\(newFileKind.fileExtension) extension."
            return false
        }

        let fileName = enteredExtension.isEmpty ? "\(trimmedName).\(newFileKind.fileExtension)" : trimmedName
        let destinationDirectory =
            newFileDestinationRelativePath.isEmpty
            ? projectURL
            : projectURL.appendingPathComponent(newFileDestinationRelativePath, isDirectory: true)
        let resolvedProjectURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirectoryURL = destinationDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard
            resolvedDirectoryURL.path == resolvedProjectURL.path
                || resolvedDirectoryURL.path.hasPrefix("\(resolvedProjectURL.path)/")
        else {
            newFileErrorMessage = "The selected folder is outside the project."
            return false
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedDirectoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            newFileErrorMessage = "The selected folder no longer exists."
            return false
        }

        let destinationURL = resolvedDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            newFileErrorMessage = "A file named \(fileName) already exists."
            return false
        }

        do {
            try newFileKind.initialContent(fileName: fileName).write(to: destinationURL, atomically: true, encoding: .utf8)
            projectSidebar.items = Self.projectTreeItems(for: project, fileManager: fileManager)
            toolbar.searchableItems = projectSidebar.items
            syncInspectorTextureAssets()
            refreshSourceControl()

            let relativePath = relativeProjectPath(for: destinationURL.path)
            if let item = projectSidebar.items.first(where: { $0.relativePath == relativePath }) {
                openProjectItem(item)
            }
            appendOutput("Created \(relativePath)")
            dismissNewFileDialog()
            return true
        } catch {
            newFileErrorMessage = "Unable to create the file: \(error.localizedDescription)"
            return false
        }
    }

    var dependencyLocationBinding: Binding<String> {
        Binding(get: { self.dependencyLocation }, set: { self.dependencyLocation = $0 })
    }

    var dependencyRequirementBinding: Binding<String> {
        Binding(get: { self.dependencyRequirement }, set: { self.dependencyRequirement = $0 })
    }

    var projectResourceRootsBinding: Binding<String> {
        Binding(get: { self.projectResourceRootsText }, set: { self.projectResourceRootsText = $0 })
    }

    var projectDisplayNameBinding: Binding<String> {
        Binding(get: { self.projectDisplayNameText }, set: { self.projectDisplayNameText = $0 })
    }

    var projectBundleIdentifierBinding: Binding<String> {
        Binding(get: { self.projectBundleIdentifierText }, set: { self.projectBundleIdentifierText = $0 })
    }

    var projectMainSceneBinding: Binding<String> {
        Binding(get: { self.projectMainSceneText }, set: { self.projectMainSceneText = $0 })
    }

    var projectRunArgumentsBinding: Binding<String> {
        Binding(get: { self.projectRunArgumentsText }, set: { self.projectRunArgumentsText = $0 })
    }

    func selectRunDestination(_ destination: EditorRunDestination) {
        selectedRunDestination = destination
        // A paired device is session state, not a change to project platform settings.
        guard destination != .player else {
            return
        }
        guard let projectURL else {
            return
        }
        do {
            try EditorProjectStore(fileManager: fileManager).setRunDestination(destination.adaProjectDestination, at: projectURL)
            projectSettingsStatusMessage = "Run destination saved."
        } catch {
            projectSettingsStatusMessage = "Failed to save run destination: \(error.localizedDescription)"
        }
    }

    func addProjectDependency() {
        guard let projectURL else {
            dependencyStatusMessage = "No project is open."
            return
        }
        let location = dependencyLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty else {
            dependencyStatusMessage = "Enter a package URL or local path."
            return
        }

        do {
            let store = EditorProjectStore(fileManager: fileManager)
            let changed: Bool
            if location.hasPrefix("https://") || location.hasPrefix("http://") || location.hasPrefix("ssh://") || location.hasPrefix("git@") {
                changed = try store.addDependency(
                    to: projectURL,
                    url: location,
                    requirement: dependencyRequirement.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } else {
                changed = try store.addLocalDependency(to: projectURL, path: location)
            }
            dependencyStatusMessage = changed ? "Dependency added. Resolving package graph…" : "Dependency is already present."
            dependencyLocation = ""
            if changed {
                bootstrapWorkspaceIfNeeded(force: true)
            }
        } catch {
            dependencyStatusMessage = "Failed to add dependency: \(error.localizedDescription)"
        }
    }

    func removeProjectDependency(identity: String) {
        guard let projectURL else {
            dependencyStatusMessage = "No project is open."
            return
        }
        do {
            let changed = try EditorProjectStore(fileManager: fileManager).removeDependency(from: projectURL, identity: identity)
            dependencyStatusMessage = changed ? "Removed \(identity). Resolving package graph…" : "Dependency \(identity) was not found."
            if changed {
                bootstrapWorkspaceIfNeeded(force: true)
            }
        } catch {
            dependencyStatusMessage = "Failed to remove \(identity): \(error.localizedDescription)"
        }
    }

    func saveProjectSettings(runtime: AdaProjectRuntime? = nil, inputActions: [InputAction]? = nil) {
        guard let projectURL else {
            projectSettingsStatusMessage = "No project is open."
            return
        }

        do {
            var settings = try ProjectSystem.loadProject(at: projectURL, fileManager: fileManager)
            let targetName: String
            if settings.build.system == .swiftpm {
                guard let selectedRunTargetName else {
                    projectSettingsStatusMessage = "Load the package and select an executable target first."
                    return
                }
                targetName = selectedRunTargetName
            } else {
                targetName = ""
            }
            if let inputActions {
                settings.inputActions = inputActions
            }
            settings.project.displayName = Self.optionalText(from: projectDisplayNameText)
            settings.project.bundleIdentifier = Self.optionalText(from: projectBundleIdentifierText)
            settings.editor.startupScene = Self.optionalText(from: projectMainSceneText)
            settings.paths.resourceRoots = Self.pathList(from: projectResourceRootsText)
            settings.build.includedFiles = projectIncludedFiles
            settings.build.excludedFiles = projectExcludedFiles
            settings.run.destination = selectedRunDestination.adaProjectDestination
            settings.run.arguments = Self.lineList(from: projectRunArgumentsText)
            if let runtime {
                settings.runtime = runtime
                if settings.build.system.isAdaScript {
                    settings.runtime.entry.scene = settings.editor.startupScene
                }
            }
            try EditorProjectStore(fileManager: fileManager).saveProjectSettings(settings, at: projectURL, targetName: targetName)
            projectSettingsStatusMessage =
                settings.build.system == .adaScript
                ? "Project settings saved to .ada/project.json."
                : "Project settings saved to .ada/project.json and Package.swift."
            bootstrapWorkspaceIfNeeded(force: true)
        } catch {
            projectSettingsStatusMessage = "Failed to save project settings: \(error.localizedDescription)"
        }
    }

    static func pathList(from text: String) -> [String] {
        var seen = Set<String>()
        return
            text
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func lineList(from text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func optionalText(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func editorRunDestination(from destination: AdaProjectRunDestination) -> EditorRunDestination {
        switch destination {
        case .macOS: .macOS
        case .iPadOS: .iPadOS
        case .web: .web
        }
    }

    var runProducts: [String] {
        packageModel?.executableProducts.map(\.name).sorted() ?? []
    }

    var selectedRunTargetName: String? {
        guard let productName = selectedRunProduct ?? runProducts.first else {
            return nil
        }
        return packageModel?.executableTargetName(forProductNamed: productName)
    }

    var testTargets: [String] {
        packageModel?.testTargets.sorted() ?? []
    }
}
