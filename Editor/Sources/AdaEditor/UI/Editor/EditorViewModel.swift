@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

enum EditorAdaScriptProjectBuildOutcome: Sendable {
    case success(EditorAdaScriptProjectBuildArtifact)
    case projectFailure(ProjectSystemError)
    case adaScriptFailure(EditorAdaScriptProjectBuildError)
    case failure(String)
}

@Observable
@MainActor
final class EditorViewModel {
    let performance = EditorPerformanceModel()
    let playerSession = EditorPlayerSession()
    var playerPairingWindow: UIWindow?
    let debugger = EditorDebugger()
    let textSearch = EditorTextSearchModel()
    var showsNotifications = false
    var notificationTab: EditorNotificationTab = .notifications
    var notificationWorkspaceRunID: String?
    let project: EditorProjectReference?
    let libraries = EditorLibrariesViewModel()
    var toolbar: EditorToolbarViewModel
    var toolStrip: EditorToolStripViewModel
    var projectSidebar: EditorProjectSidebarViewModel
    var workbench: EditorWorkbenchViewModel
    var inspectorSidebar: EditorInspectorSidebarViewModel
    var animationPanel: EditorAnimationPanelViewModel
    var agent: EditorAgentViewModel
    var sourceControl: EditorSourceControlViewModel
    var footer: EditorFooterViewModel
    var showsDebugOverlay: UIDebugOverlayMode?
    var activeOutputTab: String
    var workspaceStatus: EditorWorkspaceStatus {
        didSet {
            if case let .failed(message) = workspaceStatus, workspaceStatus != oldValue, notificationWorkspaceRunID == nil {
                reportProjectError(message)
            }
        }
    }
    var packageModel: SwiftPackageModel?
    var gameLogLines: [EditorWorkspaceLogLine] = []
    var activeLogSource = "Game"
    @ObservationIgnored var runtimeLogCursor = 0
    var workspaceOutputIsGame = false
    var outputLines: [EditorWorkspaceLogLine]
    var buildActivity: EditorBuildActivity?
    var problems: [EditorDiagnostic]
    var symbolReferences: [EditorSourceReference]
    var selectedRunProduct: String?
    var selectedRunDestination: EditorRunDestination
    var dependencyLocation = ""
    var dependencyRequirement = #"from: "1.0.0""#
    var dependencyStatusMessage = ""
    var projectDisplayNameText = ""
    var projectBundleIdentifierText = ""
    var projectMainSceneText = ""
    var projectResourceRootsText = ""
    var projectIncludedFiles: [String] = []
    var projectExcludedFiles: [String] = []
    var projectRunArgumentsText = ""
    var projectSettingsStatusMessage = ""
    var selectedTestFilter: String
    var playModeState: EditorPlayModeState
    var isNewFileDialogPresented = false
    var pendingDeleteProjectItem: EditorProjectSidebarViewModel.Item?
    var newFileKind = EditorNewFileKind.scene
    var isNewFileKindPreselected = false
    var newFileName = ""
    var newFileDestinationRelativePath = ""
    var newFileErrorMessage: String?
    var requestedSettingsSection: EditorSettingsSection?
    var requestedSettingsPage: String?
    var settingsPresentationToken = 0
    var scenePlayRuntime: EditorScenePlayRuntime?

    var showLeftPanel = true
    var showRightPanel = false
    var showBottomPanel = false

    @ObservationIgnored
    let workspaceService: any SwiftPMWorkspaceServicing
    @ObservationIgnored
    let sourceControlService: any GitRepositoryServicing
    @ObservationIgnored
    let fileManager: FileManager
    @ObservationIgnored
    let previewBuilder: EditorPreviewBuilder
    @ObservationIgnored
    let adaScriptPreviewBuilder: EditorAdaScriptPreviewBuilder
    @ObservationIgnored
    let externalURLOpener: @MainActor (URL) -> Bool
    @ObservationIgnored
    let previewLibrary = EditorPreviewDynamicLibrary()
    @ObservationIgnored
    var workspaceTask: Task<Void, Never>?
    @ObservationIgnored
    var sourceControlTask: Task<Void, Never>?
    @ObservationIgnored
    var previewTask: Task<Void, Never>?
    @ObservationIgnored
    var previewBuildGeneration = 0
    @ObservationIgnored
    var adaScriptRuntimeWindow: UIWindow?
    #if os(macOS)
        @ObservationIgnored
        var adaScriptWebServer: Process?
        @ObservationIgnored
        var adaScriptWebRunDirectory: URL?
        @ObservationIgnored
        var adaScriptWebExportRunner: EditorProcessRunner?
    #endif
    @ObservationIgnored
    var pendingWebRunURL: URL?
    @ObservationIgnored
    var completionTask: Task<Void, Never>?
    @ObservationIgnored
    var sourceAnalysisTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    var autosaveTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    let autosaveDelay: Duration
    @ObservationIgnored
    var didStartEditorSession = false
    @ObservationIgnored
    var projectFileWatcher: EditorProjectFileWatcher?
    @ObservationIgnored
    var lastRememberedProjectFile: String?
    @ObservationIgnored
    var latestSourceHoverKey: String?
    @ObservationIgnored
    var lastLoggedWorkspaceProgressPhase: SwiftPMWorkspaceBootstrapPhase?
    @ObservationIgnored
    var pendingWorkspaceStandardOutput = ""
    @ObservationIgnored
    var pendingWorkspaceStandardError = ""
    @ObservationIgnored
    var didReceiveStreamingWorkspaceOutput = false

    init(
        project: EditorProjectReference? = nil,
        fileManager: FileManager = .default,
        workspaceService: any SwiftPMWorkspaceServicing = SwiftPMWorkspaceService(),
        sourceControlService: any GitRepositoryServicing = GitRepositoryService(),
        previewBuilder: EditorPreviewBuilder = EditorPreviewBuilder(),
        adaScriptPreviewBuilder: EditorAdaScriptPreviewBuilder = EditorAdaScriptPreviewBuilder(),
        externalURLOpener: @escaping @MainActor (URL) -> Bool = EditorPlatformFileActions.openInDefaultApplication,
        toolbar: EditorToolbarViewModel = EditorToolbarViewModel(),
        toolStrip: EditorToolStripViewModel = EditorToolStripViewModel(),
        projectSidebar: EditorProjectSidebarViewModel? = nil,
        workbench: EditorWorkbenchViewModel? = nil,
        inspectorSidebar: EditorInspectorSidebarViewModel = EditorInspectorSidebarViewModel(),
        animationPanel: EditorAnimationPanelViewModel = EditorAnimationPanelViewModel(),
        agent: EditorAgentViewModel? = nil,
        sourceControl: EditorSourceControlViewModel = EditorSourceControlViewModel(),
        footer: EditorFooterViewModel = EditorFooterViewModel(),
        activeOutputTab: String = "Problems",
        workspaceStatus: EditorWorkspaceStatus = .idle,
        packageModel: SwiftPackageModel? = nil,
        outputLines: [EditorWorkspaceLogLine]? = nil,
        buildActivity: EditorBuildActivity? = nil,
        problems: [EditorDiagnostic] = [],
        symbolReferences: [EditorSourceReference] = [],
        selectedRunProduct: String? = nil,
        selectedRunDestination: EditorRunDestination? = nil,
        selectedTestFilter: String = "",
        playModeState: EditorPlayModeState = .editing,
        autosaveDelay: Duration = .milliseconds(350)
    ) {
        let savedProject = project.flatMap {
            try? ProjectSystem.loadProject(at: URL(fileURLWithPath: $0.path, isDirectory: true), fileManager: fileManager)
        }
        let scriptableObjectSupport: EditorScriptableObjectCatalogLoader.Result? = project.flatMap { reference in
            guard let savedProject, savedProject.build.system.isAdaScript else {
                return nil
            }
            return try? EditorScriptableObjectCatalogLoader.load(
                project: savedProject,
                at: URL(fileURLWithPath: reference.path, isDirectory: true),
                fileManager: fileManager
            )
        }
        let sourceRootTarget = savedProject.flatMap { savedProject -> EditorProjectSidebarViewModel.SourceRootTarget? in
            guard savedProject.build.system.isAdaScript else {
                return nil
            }
            let moduleName = savedProject.runtime.moduleName.isEmpty ? (project?.name ?? "Sources") : savedProject.runtime.moduleName
            return EditorProjectSidebarViewModel.SourceRootTarget(
                relativePath: savedProject.paths.sources ?? "Sources",
                title: moduleName
            )
        }

        self.project = project
        self.workspaceService = workspaceService
        self.sourceControlService = sourceControlService
        self.fileManager = fileManager
        self.previewBuilder = previewBuilder
        self.adaScriptPreviewBuilder = adaScriptPreviewBuilder
        self.externalURLOpener = externalURLOpener
        self.autosaveDelay = autosaveDelay
        self.toolbar = toolbar
        self.toolStrip = toolStrip
        self.projectSidebar =
            projectSidebar
            ?? EditorProjectSidebarViewModel(
                items: Self.projectTreeItems(for: project, fileManager: fileManager),
                sourceRootTarget: sourceRootTarget
            )
        self.workbench = workbench ?? Self.defaultWorkbench(for: project)
        inspectorSidebar.scriptableObjectCatalog = scriptableObjectSupport?.descriptors ?? []
        self.inspectorSidebar = inspectorSidebar
        self.animationPanel = animationPanel
        self.agent = agent ?? EditorAgentViewModel(project: project, fileManager: fileManager)
        self.sourceControl = sourceControl
        self.activeOutputTab = activeOutputTab
        self.footer = footer
        self.workspaceStatus = workspaceStatus
        self.packageModel = packageModel
        self.outputLines = outputLines ?? (project == nil ? AdaEngineStyleContent.logLines.map { EditorWorkspaceLogLine(text: $0) } : [])
        self.buildActivity = buildActivity
        self.problems = problems
        self.symbolReferences = symbolReferences
        self.selectedRunProduct = selectedRunProduct
        #if os(iOS)
            self.selectedRunDestination = selectedRunDestination ?? .iPadOS
        #else
            self.selectedRunDestination = selectedRunDestination ?? Self.editorRunDestination(from: savedProject?.run.destination ?? .macOS)
        #endif
        self.projectDisplayNameText = savedProject?.project.displayName ?? savedProject?.project.name ?? project?.name ?? ""
        self.projectBundleIdentifierText = savedProject?.project.bundleIdentifier ?? ""
        self.projectMainSceneText = savedProject?.runtime.entry.scene ?? savedProject?.editor.startupScene ?? ""
        self.projectResourceRootsText = savedProject?.paths.resourceRoots.joined(separator: "\n") ?? ""
        self.projectIncludedFiles = savedProject?.build.includedFiles ?? []
        self.projectExcludedFiles = savedProject?.build.excludedFiles ?? []
        self.projectRunArgumentsText = savedProject?.run.arguments.joined(separator: "\n") ?? ""
        self.scenePlayRuntime = scriptableObjectSupport?.playRuntime
        self.selectedTestFilter = selectedTestFilter
        self.playModeState = playModeState
        self.inspectorSidebar.textureAssets = Self.textureAssets(from: self.projectSidebar.items)
        self.inspectorSidebar.tileMapAssets = Self.tileMapAssets(from: self.projectSidebar.items)
        self.inspectorSidebar.sceneAssets = Self.sceneAssets(from: self.projectSidebar.items)
        self.inspectorSidebar.uiSourcePaths = Self.uiSourcePaths(from: self.projectSidebar.items)
        self.inspectorSidebar.uiSceneFiles = Self.uiSceneFiles(from: self.projectSidebar.items)
        self.inspectorSidebar.uiSourceContent = { [weak workbench = self.workbench] path in
            let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            return workbench?.openDocuments
                .compactMap { document -> String? in
                    guard
                        case let .ui(ui) = document, let sourcePath = ui.absolutePath,
                        URL(fileURLWithPath: sourcePath).standardizedFileURL.resolvingSymlinksInPath() == target
                    else {
                        return nil
                    }
                    return ui.content
                }
                .first
        }
        self.toolbar.searchableItems = self.projectSidebar.items
        self.agent.setProjectFileChangedHandler { [weak self] relativePath in
            self?.handleAgentProjectFileChanged(relativePath: relativePath, fileManager: fileManager)
        }
        self.workbench.setActiveDocumentWillChangeHandler { [weak self] in
            self?.saveActiveDocumentIfNeeded()
        }
        self.workbench.setActiveDocumentChangedHandler { [weak self] in
            self?.synchronizeAgentSceneContext()
            self?.rememberDebugSource()
            self?.rememberActiveProjectDocument()
        }
        self.workbench.setDocumentEditedHandler { [weak self] documentID in
            self?.updateDebugSource(documentID: documentID)
            self?.scheduleAutosave(documentID: documentID)
            self?.scheduleSourceAnalysis(documentID: documentID)
        }
        self.workbench.achievements = EditorAchievementBootstrap.center
        self.workbench.achievementResourceRoot = projectAssetsURL
        self.workbench.achievementAdaScriptProject = savedProject?.build.system.isAdaScript == true
        libraries.load(for: self)
        configureDebugger()
        if workbench == nil {
            restoreProjectDocument()
        }
        synchronizeAgentSceneContext()
    }
}
