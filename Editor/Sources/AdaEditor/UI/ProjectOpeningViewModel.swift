//
//  ProjectOpeningViewModel.swift
//  AdaEngine
//

@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

enum ProjectOpeningSection: String, CaseIterable, Equatable, Sendable {
    case projects
    case templates
    case samples

    var title: String {
        rawValue.capitalized
    }

    var icon: String {
        switch self {
        case .projects: "\u{E2C7}"
        case .templates: "\u{E871}"
        case .samples: "\u{E034}"
        }
    }
}

struct ProjectOpeningDiagnostic: Equatable, Identifiable, Sendable {
    var id: String { code + ":" + (fieldPath ?? "") + ":" + message }
    var code: String
    var fieldPath: String?
    var message: String
    var recoverySuggestion: String

    init(error: ProjectSystemError) {
        self.code = error.code
        self.fieldPath = error.fieldPath
        self.message = error.message
        self.recoverySuggestion = error.recoverySuggestion
    }
}

@Observable
@MainActor
final class ProjectOpeningViewModel {
    var projectAvailability: [String: ProjectOpeningAvailability] = [:]
    var recentProjects: [EditorProjectReference] = []
    var projectName: String = "My_Game"
    var projectLocation: String = ""
    var isCreatingNewProject = false
    var existingProjectPath: String = ""
    var searchQuery: String = ""
    var selectedSection = ProjectOpeningSection.projects
    var selectedTemplate = EditorProjectTemplate.adaScript
    var selectedProject: EditorProjectReference?
    var statusMessage: String = "Select a recent Ada project, create a blank one, or open an existing project."
    var validationDiagnostics: [ProjectOpeningDiagnostic] = []
    var projectToOpenInEditor: EditorProjectReference?
    var projectToOpenInEditorToken = 0
    var isOpeningLastProject = false
    var shouldCreateGitRepository = true
    var shouldCreateProjectPackage = EditorProjectStore.defaultUsesProjectPackage
    var projectBeingRenamed: EditorProjectReference?
    var renamedProjectName = ""
    var recentProjectError: String?

    var renamedProjectNameBinding: Binding<String> {
        Binding(get: { self.renamedProjectName }, set: { self.renamedProjectName = $0 })
    }

    func beginRenamingProject(_ project: EditorProjectReference) {
        selectProject(project)
        recentProjectError = nil
        renamedProjectName = project.name
        projectBeingRenamed = project
    }

    func cancelRenamingProject() {
        projectBeingRenamed = nil
        recentProjectError = nil
    }

    func renameRecentProject() {
        guard let reference = projectBeingRenamed else {
            return
        }
        do {
            _ = try store.renameProject(reference, to: renamedProjectName)
            reloadRecentProjects()
            projectBeingRenamed = nil
            recentProjectError = nil
        } catch {
            recentProjectError = "Could not rename project: \(error.localizedDescription)"
        }
    }

    func removeRecentProject(_ project: EditorProjectReference) {
        do {
            try store.removeRecentProject(project)
            reloadRecentProjects()
            projectAvailability.removeValue(forKey: project.path)
            if existingProjectPath == project.path {
                existingProjectPath = ""
            }
            if projectBeingRenamed?.id == project.id {
                projectBeingRenamed = nil
            }
            recentProjectError = nil
        } catch {
            recentProjectError = "Could not remove project: \(error.localizedDescription)"
        }
    }

    var projectTemplateBinding: Binding<String> {
        Binding(
            get: { self.selectedTemplate.displayName },
            set: { name in
                if let template = self.availableTemplates.first(where: { $0.displayName == name }) {
                    self.selectedTemplate = template
                }
            }
        )
    }

    var projectNameBinding: Binding<String> {
        Binding(get: { self.projectName }, set: { self.projectName = $0 })
    }

    var projectLocationBinding: Binding<String> {
        Binding(get: { self.projectLocation }, set: { self.projectLocation = $0 })
    }

    var shouldCreateGitRepositoryBinding: Binding<Bool> {
        Binding(get: { self.shouldCreateGitRepository }, set: { self.shouldCreateGitRepository = $0 })
    }

    var existingProjectPathBinding: Binding<String> {
        Binding(get: { self.existingProjectPath }, set: { self.existingProjectPath = $0 })
    }

    var existingProjectPathDisplayText: String {
        let trimmed = existingProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Choose an Ada project folder or .adaproject package"
        }
        return Self.abbreviatedPath(trimmed)
    }

    var searchQueryBinding: Binding<String> {
        Binding(get: { self.searchQuery }, set: { self.searchQuery = $0 })
    }

    var filteredRecentProjects: [EditorProjectReference] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return recentProjects
        }

        return recentProjects.filter { project in
            project.name.localizedCaseInsensitiveContains(query)
                || project.path.localizedCaseInsensitiveContains(query)
        }
    }

    var detailProject: EditorProjectReference? {
        selectedProject
    }

    var validationSummary: String? {
        validationDiagnostics.first.map { diagnostic in
            if let fieldPath = diagnostic.fieldPath {
                return "\(diagnostic.code) at \(fieldPath)"
            }
            return diagnostic.code
        }
    }

    var hasValidProjectName: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canCreateProject: Bool {
        hasValidProjectName && !projectLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var projectLocationDisplayText: String {
        let trimmed = projectLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Choose a folder"
        }
        return Self.abbreviatedPath(trimmed)
    }

    var availableTemplates: [EditorProjectTemplate] { store.distribution.projectTemplates }
    var supportsSwiftProjects: Bool {
        store.distribution.supportsSwiftProjects
    }

    private let store: EditorProjectStore

    init(store: EditorProjectStore = EditorProjectStore()) {
        self.store = store
        self.shouldCreateGitRepository = store.distribution.supportsSwiftProjects
        reloadRecentProjects()
    }

    func reloadRecentProjects() {
        do {
            recentProjects = try store.loadProjects()
            if let selectedProject,
                recentProjects.contains(where: { $0.path == selectedProject.path }) {
                self.selectedProject = recentProjects.first(where: { $0.path == selectedProject.path })
            } else {
                selectedProject = nil
            }
        } catch {
            setFailureStatus(prefix: "Failed to load recent projects", error: error)
        }
    }

    func refreshProjectAvailability() async {
        let locations = recentProjects.map { ($0.path, retainedProjectURL(for: $0)) }
        // File enumeration can block on external or cloud volumes; only immutable URLs cross actors.
        let snapshot =
            await Task.detached(priority: .utility) {
                Dictionary(
                    locations.map { path, url in
                        (path, ProjectOpeningAvailability.inspect(at: url))
                    },
                    uniquingKeysWith: { _, latest in latest }
                )
            }
            .value
        guard !Task.isCancelled, projectAvailability != snapshot else {
            return
        }
        projectAvailability = snapshot
    }

    /// Opens the most recent project without performing potentially blocking filesystem I/O on the main actor.
    @discardableResult
    func openLastProjectIfAvailable() async -> Bool {
        guard !isOpeningLastProject else {
            return false
        }

        reloadRecentProjects()
        guard let lastProject = recentProjects.first else {
            clearValidationDiagnostics()
            statusMessage = "Select a recent Ada project, create a blank one, or open an existing project."
            return false
        }

        isOpeningLastProject = true
        defer { isOpeningLastProject = false }
        let selectedPathBeforeOpening = selectedProject?.path
        let storageURL = store.storageURL
        let adaEnginePackageURL = store.adaEnginePackageURL
        let documentsDirectoryURL = store.documentsDirectoryURL
        let distribution = store.distribution
        let lastProjectURL = retainedProjectURL(for: lastProject)

        // Foundation does not provide asynchronous file reads here. Keep the blocking project validation
        // and manifest update off the UI actor so unavailable or cloud-backed paths cannot freeze the window.
        let result =
            await Task.detached(priority: .userInitiated) {
                let backgroundStore = EditorProjectStore(
                    storageURL: storageURL,
                    fileManager: FileManager(),
                    adaEnginePackageURL: adaEnginePackageURL,
                    documentsDirectoryURL: documentsDirectoryURL,
                    distribution: distribution
                )
                guard backgroundStore.fileManager.fileExists(atPath: lastProjectURL.path) else {
                    return BackgroundProjectOpenResult.unavailable
                }

                do {
                    let openedProject = try backgroundStore.openProject(
                        at: lastProjectURL
                    )
                    return .opened(openedProject)
                } catch let error as ProjectSystemError {
                    return .projectFailure(error)
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
            .value

        guard selectedProject?.path == selectedPathBeforeOpening, projectToOpenInEditor == nil else {
            return false
        }

        return applyBackgroundProjectOpenResult(result, lastProject: lastProject)
    }

    private func applyBackgroundProjectOpenResult(
        _ result: BackgroundProjectOpenResult,
        lastProject: EditorProjectReference
    ) -> Bool {
        switch result {
        case let .opened(openedProject):
            isCreatingNewProject = false
            selectedProject = openedProject
            clearValidationDiagnostics()
            statusMessage = "Opened project: \(openedProject.path)"
            reloadRecentProjects()
            projectToOpenInEditor = openedProject
            projectToOpenInEditorToken += 1
            return true
        case .unavailable:
            selectedProject = nil
            clearValidationDiagnostics()
            statusMessage = "Last project is no longer available: \(lastProject.path)"
        case let .projectFailure(error):
            selectedProject = nil
            setFailureStatus(prefix: "Failed to open project", error: error)
        case let .failure(message):
            selectedProject = nil
            clearValidationDiagnostics()
            statusMessage = "Failed to open project: \(message)"
        }
        return false
    }

    func selectProject(_ reference: EditorProjectReference) {
        isCreatingNewProject = false
        selectedProject = reference
        existingProjectPath = reference.path
        clearValidationDiagnostics()
        statusMessage = "Ready to open \(reference.name)."
    }

    func createProject(openInEditor: Bool = false) {
        guard canCreateProject else {
            clearValidationDiagnostics()
            statusMessage = "Choose a project name and location before creating."
            return
        }

        do {
            let createdProject = try store.createProject(
                named: projectName,
                at: URL(fileURLWithPath: projectLocation, isDirectory: true),
                template: selectedTemplate,
                asPackage: shouldCreateProjectPackage
            )
            if shouldCreateGitRepository && supportsSwiftProjects {
                let gitResult = initializeGitRepositoryIfNeeded(at: createdProject.path)
                if let gitResult {
                    statusMessage = "Created project: \(createdProject.path). \(gitResult)"
                } else {
                    statusMessage = "Created project: \(createdProject.path)"
                }
            } else {
                statusMessage = "Created project: \(createdProject.path)"
            }
            EditorAchievementBootstrap.center?.record([.firstProject: 1])
            isCreatingNewProject = false
            selectedProject = createdProject
            clearValidationDiagnostics()
            reloadRecentProjects()
            if openInEditor {
                projectToOpenInEditor = createdProject
                projectToOpenInEditorToken += 1
            }
        } catch {
            setFailureStatus(prefix: "Failed to create project", error: error)
        }
    }

    func openProject() {
        openProject(atPath: existingProjectPath, openInEditor: true)
    }

    func openProject(at url: URL) {
        existingProjectPath = url.path
        openProject(atPath: url.path, openInEditor: true)
    }

    func openSelectedProject() {
        guard let project = detailProject else {
            statusMessage = "Select a project first."
            return
        }
        openProject(at: retainedProjectURL(for: project), openInEditor: true)
    }

    func openRecentProject(_ reference: EditorProjectReference) {
        selectProject(reference)
        openProject(at: retainedProjectURL(for: reference), openInEditor: true)
    }

    func beginCreateNewProject(
        template: EditorProjectTemplate? = nil,
        suggestedName: String? = nil
    ) {
        selectedProject = nil
        shouldCreateProjectPackage = EditorProjectStore.defaultUsesProjectPackage
        shouldCreateGitRepository = supportsSwiftProjects
        if let template, availableTemplates.contains(template) {
            selectedTemplate = template
        }
        if let suggestedName {
            projectName = suggestedName
        }
        isCreatingNewProject = true
        clearValidationDiagnostics()
        statusMessage = "Choose a name and location for the new Ada project."
    }

    func setProjectLocation(_ url: URL) {
        projectLocation = url.standardizedFileURL.path
        statusMessage = "Project location: \(projectLocationDisplayText)"
    }

    func createBlankTemplateProject() {
        if projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            projectName = "BlankAdaProject"
        }
        createProject(openInEditor: true)
    }

    func selectSection(_ section: ProjectOpeningSection) {
        selectedSection = section
        isCreatingNewProject = false
        selectedProject = nil
        clearValidationDiagnostics()
        statusMessage = "Browse \(section.title.lowercased())."
    }

    func abbreviatedPath(for project: EditorProjectReference) -> String {
        Self.abbreviatedPath(project.path)
    }

    func engineVersion(for project: EditorProjectReference?) -> String {
        guard let project else {
            return "Ada SwiftPM"
        }
        let metadataURL = ProjectSystem.metadataURL(forProjectAt: URL(fileURLWithPath: project.path, isDirectory: true))
        guard
            let data = try? Data(contentsOf: metadataURL),
            let adaProject = try? ProjectSystem.loadProject(from: data)
        else {
            return "Ada SwiftPM"
        }
        return adaProject.engine.minimumVersion.map { "Ada \($0)" } ?? "Ada SwiftPM"
    }

    func lastOpenedText(for project: EditorProjectReference?) -> String {
        guard let project else {
            return "Never"
        }
        return Self.relativeDateFormatter.localizedString(for: project.lastOpenedAt, relativeTo: Date())
    }

    func consumeProjectToOpenInEditor() -> EditorProjectReference? {
        defer { projectToOpenInEditor = nil }
        return projectToOpenInEditor
    }

    private func setFailureStatus(prefix: String, error: Error) {
        if let projectError = error as? ProjectSystemError {
            let diagnostic = ProjectOpeningDiagnostic(error: projectError)
            validationDiagnostics = [diagnostic]
            statusMessage = "\(prefix): \(projectError.message) \(projectError.recoverySuggestion)"
        } else {
            validationDiagnostics = []
            statusMessage = "\(prefix): \(error.localizedDescription)"
        }
    }

    private func clearValidationDiagnostics() {
        validationDiagnostics = []
    }

    static func abbreviatedPath(_ path: String) -> String {
        EditorProjectPathDisplayFormatter.string(for: path)
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private func initializeGitRepositoryIfNeeded(at path: String) -> String? {
        #if os(macOS) || os(Linux) || os(Windows)
            let command: [String]
            #if os(Windows)
                command = ["git", "init"]
            #else
                command = ["/usr/bin/env", "git", "init"]
            #endif

            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
            process.currentDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return "Git initialization failed: \(error.localizedDescription)"
            }

            guard process.terminationStatus == 0 else {
                let outputText = output.readableString
                let errorText = error.readableString
                let reason = outputText.isEmpty ? (errorText.isEmpty ? "exit code \(process.terminationStatus)" : errorText) : outputText
                return "Git initialization failed: \(reason)"
            }
            return nil
        #else
            return "Git initialization requires a desktop platform. The project was created without a Git repository."
        #endif
    }
}

extension Pipe {
    var readableString: String {
        String(bytes: fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

extension ProjectOpeningViewModel {
    private func openProject(atPath path: String, openInEditor: Bool = false) {
        openProject(
            at: URL(fileURLWithPath: path, isDirectory: true),
            openInEditor: openInEditor
        )
    }

    private func openProject(at url: URL, openInEditor: Bool = false) {
        do {
            isCreatingNewProject = false
            selectedProject = try store.openProject(at: url)
            clearValidationDiagnostics()
            statusMessage = "Opened project: \(selectedProject?.path ?? "")"
            reloadRecentProjects()
            if openInEditor, let selectedProject {
                projectToOpenInEditor = selectedProject
                projectToOpenInEditorToken += 1
            }
        } catch {
            selectedProject = nil
            setFailureStatus(prefix: "Failed to open project", error: error)
        }
    }

    private func retainedProjectURL(for project: EditorProjectReference) -> URL {
        let projectURL = store.resolveProjectURL(for: project)
        #if canImport(UIKit)
            return ProjectOpenPicker.retainSecurityScopedAccess(to: projectURL)
        #else
            return projectURL
        #endif
    }
}

extension ProjectOpeningViewModel {
    func applyProjectLocationPickerResult(_ result: ProjectLocationPickerResult) {
        switch result {
        case let .selected(url):
            setProjectLocation(url)
        case .cancelled:
            statusMessage = "Project location selection cancelled."
        case let .unavailable(message):
            statusMessage = "Could not choose a project location: \(message)"
        }
    }
}

private enum BackgroundProjectOpenResult: Sendable {
    case opened(EditorProjectReference)
    case unavailable
    case projectFailure(ProjectSystemError)
    case failure(String)
}

struct ProjectOpeningAvailability: Equatable, Sendable {
    var isAvailable: Bool
    var containsSwiftCode: Bool

    static func inspect(at url: URL) -> Self {
        let fileManager = FileManager()
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
            fileManager.isReadableFile(atPath: url.path),
            let project = try? ProjectSystem.loadProject(at: url, fileManager: fileManager)
        else {
            return Self(isAvailable: false, containsSwiftCode: false)
        }
        guard
            project.build.system == .swiftpm,
            fileManager.isReadableFile(atPath: url.appendingPathComponent("Package.swift").path)
        else {
            return Self(isAvailable: true, containsSwiftCode: false)
        }
        let sourceRoots = [project.paths.sources ?? "Sources"] + project.build.includedFiles
        let containsSwift = sourceRoots.contains { path in
            let sourceURL = url.appendingPathComponent(path)
            if isSwiftSource(sourceURL) {
                return true
            }
            guard
                let files = fileManager.enumerator(
                    at: sourceURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else {
                return false
            }
            for case let file as URL in files where isSwiftSource(file) {
                return true
            }
            return false
        }
        return Self(isAvailable: true, containsSwiftCode: containsSwift)
    }

    private static func isSwiftSource(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "swift"
            && url.lastPathComponent != "Package.swift"
            && !url.lastPathComponent.hasPrefix("Package@swift-")
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}
