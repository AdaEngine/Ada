import Foundation
import Testing

@testable import AdaEditor

@Suite("EditorProjectStore")
struct EditorProjectStoreTests {
    @Test("default storage URL points to Application Support AdaEditor projects json")
    func defaultStorageURL() {
        let url = EditorProjectStore.defaultStorageURL()

        #expect(url.lastPathComponent == "projects.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "AdaEditor")
    }

    @Test("create project writes SwiftPM package, Ada metadata, and recent projects")
    func createProjectPersistsRecentProject() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectStore")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let storageURL = rootURL.appendingPathComponent("Application Support/AdaEditor/projects.json")
        let projectsRoot = rootURL.appendingPathComponent("Projects", isDirectory: true)
        let store = EditorProjectStore(storageURL: storageURL)
        let openedAt = try #require(ISO8601DateFormatter().date(from: "2026-02-19T10:00:00Z"))

        let reference = try store.createProject(named: "My Game", at: projectsRoot, openedAt: openedAt)
        let projectURL = projectsRoot.appendingPathComponent("My-Game", isDirectory: true)

        #expect(reference.name == "My-Game")
        #expect(reference.path == projectURL.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("Package.swift").path))
        let manifest = try String(contentsOf: projectURL.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(manifest.contains(#".package(name: "AdaEngine", path: "\#(adaEnginePackageURL().path)")"#))
        #expect(!manifest.contains(#".package(path: "../../AdaEngine")"#))
        #expect(!manifest.contains(#"path: ".""#))
        #expect(manifest.contains(#".executable(name: "My-Game", targets: ["My_Game"])"#))
        #expect(manifest.contains(".macOS(.v15)"))
        #expect(manifest.contains(".executableTarget(\n            name: \"My_Game\""))
        #expect(!manifest.contains("\n            sources:"))
        #expect(manifest.contains(#"resources: [.copy("../../Assets")]"#))
        #expect(manifest.contains(#"plugins: [.plugin(name: "AdaScriptBuildPlugin", package: "AdaEngine")]"#))
        #expect(ProjectSystem.isAdaProject(at: projectURL))
        #expect(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("README.md").path))
        #expect(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("Assets", isDirectory: true).appendingPathComponent(".gitkeep").path))
        let main = try String(contentsOf: projectURL.appendingPathComponent("Sources/My_Game/main.swift"), encoding: .utf8)
        #expect(main.contains("try await Game.main()"))
        #expect(main.contains("assetBundle: .module"))
        #expect(main.contains(".addPlugins(AdaScriptPluginsGenerated())"))
        #expect(main.contains("AdaScriptViewsGenerated.mainView"))
        #expect(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("Sources/My_Game/Main.ada").path))
        let sceneURL = projectURL.appendingPathComponent("Assets/Scenes/Main.ascn", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: sceneURL.path))
        #expect(try String(contentsOf: sceneURL, encoding: .utf8).contains("format: ada.scene"))
        let loadedProjects = try store.loadProjects()
        #expect(loadedProjects == [reference])
    }

    @Test("open existing Ada SwiftPM project validates metadata and moves project to top")
    func openProjectValidatesMetadataAndDeduplicatesRecentProjects() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectStoreOpen")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let storageURL = rootURL.appendingPathComponent("Application Support/AdaEditor/projects.json")
        let store = EditorProjectStore(storageURL: storageURL)
        let projectURL = rootURL.appendingPathComponent("Existing", isDirectory: true)
        try createSwiftPMManifest(at: projectURL)
        _ = try ProjectSystem.createDefaultProject(at: projectURL)

        let firstDate = try #require(ISO8601DateFormatter().date(from: "2026-02-19T10:00:00Z"))
        let secondDate = try #require(ISO8601DateFormatter().date(from: "2026-02-20T10:00:00Z"))

        let firstReference = try store.openProject(at: projectURL, openedAt: firstDate)
        let secondReference = try store.openProject(at: projectURL, openedAt: secondDate)
        let projects = try store.loadProjects()

        #expect(ProjectSystem.isAdaProject(at: projectURL))
        #expect(try ProjectSystem.loadProject(at: projectURL).editor.startupScene == "Assets/Scenes/Main.ascn")
        #expect(projects.count == 1)
        #expect(firstReference.id == secondReference.id)
        #expect(projects.first == secondReference)
        #expect(projects.first?.lastOpenedAt == secondDate)
    }

    @Test("open existing requires SwiftPM manifest")
    func openRequiresSwiftPMManifest() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectStoreMissingManifest")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let store = EditorProjectStore(storageURL: rootURL.appendingPathComponent("projects.json"))
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: rootURL.lastPathComponent), at: rootURL)

        do {
            _ = try store.openProject(at: rootURL)
            Issue.record("Expected openProject to throw")
        } catch let error as ProjectSystemError {
            #expect(error == .swiftPackageManifestMissing(path: "Package.swift"))
        }
    }

    @Test("open existing requires Ada metadata")
    func openRequiresAdaMetadata() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectStoreMissingMetadata")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let projectURL = rootURL.appendingPathComponent("PlainSwiftPM", isDirectory: true)
        try createSwiftPMManifest(at: projectURL)
        let store = EditorProjectStore(storageURL: rootURL.appendingPathComponent("projects.json"))

        do {
            _ = try store.openProject(at: projectURL)
            Issue.record("Expected openProject to throw")
        } catch let error as ProjectSystemError {
            #expect(error == .metadataFileMissing(path: ".ada/project.json"))
            #expect(error.recoverySuggestion.contains("New Project"))
        }
    }

    @Test("view model reports actionable validation diagnostics for invalid project folder")
    @MainActor
    func projectOpeningViewModelReportsValidationDiagnostics() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectViewModelDiagnostics")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let storageURL = rootURL.appendingPathComponent("projects.json")
        let store = EditorProjectStore(storageURL: storageURL)
        let viewModel = ProjectOpeningViewModel(store: store)
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: rootURL.lastPathComponent), at: rootURL)

        viewModel.openProject(at: rootURL)

        #expect(viewModel.detailProject == nil)
        #expect(viewModel.projectToOpenInEditor == nil)
        #expect(viewModel.validationDiagnostics.count == 1)
        #expect(viewModel.validationDiagnostics.first?.code == "project.swiftPackageManifestMissing")
        #expect(viewModel.validationDiagnostics.first?.fieldPath == "Package.swift")
        #expect(viewModel.statusMessage.contains("Choose a folder that contains Package.swift"))
    }

    @Test("view model filters recent projects and abbreviates display paths")
    @MainActor
    func projectOpeningViewModelFiltersAndFormatsProjects() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectViewModel")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let storageURL = rootURL.appendingPathComponent("projects.json")
        let store = EditorProjectStore(storageURL: storageURL)
        let firstDate = try #require(ISO8601DateFormatter().date(from: "2026-02-19T10:00:00Z"))
        let secondDate = try #require(ISO8601DateFormatter().date(from: "2026-02-20T10:00:00Z"))
        let projects = [
            EditorProjectReference(name: "NeonNights_RPG", path: rootURL.appendingPathComponent("NeonNights_RPG").path, lastOpenedAt: secondDate),
            EditorProjectReference(name: "ArchViz_Interior", path: rootURL.appendingPathComponent("ArchViz_Interior").path, lastOpenedAt: firstDate),
        ]
        try store.saveProjects(projects)

        let viewModel = ProjectOpeningViewModel(store: store)
        viewModel.searchQuery = "neon"

        #expect(viewModel.filteredRecentProjects.map(\.name) == ["NeonNights_RPG"])
        #expect(viewModel.detailProject == nil)
        viewModel.selectProject(projects[0])
        #expect(viewModel.detailProject?.name == "NeonNights_RPG")
        #expect(ProjectOpeningViewModel.abbreviatedPath(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AdaProjects/Neon").path).hasPrefix("~/"))

        let simulatorProjectPath = "/Users/developer/Library/Developer/CoreSimulator/Devices/IPAD/data/Containers/Data/Application/APP/Documents/AdaGame.adaproject"
        #expect(ProjectOpeningViewModel.abbreviatedPath(simulatorProjectPath) == "On My iPad/AdaGame.adaproject")
        viewModel.existingProjectPath = simulatorProjectPath
        #expect(viewModel.existingProjectPathDisplayText == "On My iPad/AdaGame.adaproject")

        let iCloudProjectPath = "/Users/developer/Library/Mobile Documents/com~apple~CloudDocs/AdaProjects/CloudGame.adaproject"
        #expect(ProjectOpeningViewModel.abbreviatedPath(iCloudProjectPath) == "iCloud Drive/AdaProjects/CloudGame.adaproject")
    }

    @Test("editor project switcher filters recents and excludes the current project")
    @MainActor
    func editorProjectSwitcherFiltersRecentProjects() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectSwitcherFilter")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let store = EditorProjectStore(storageURL: rootURL.appendingPathComponent("projects.json"))
        let current = EditorProjectReference(name: "CurrentGame", path: rootURL.appendingPathComponent("CurrentGame").path)
        let other = EditorProjectReference(name: "OtherGame", path: rootURL.appendingPathComponent("OtherGame").path)
        try store.saveProjects([current, other])
        let viewModel = EditorProjectSwitcherViewModel(currentProject: current, store: store)

        viewModel.toggle()
        #expect(viewModel.isPresented)
        #expect(viewModel.filteredRecentProjects.map(\.name) == ["OtherGame"])

        viewModel.searchText = "missing"
        #expect(viewModel.filteredRecentProjects.isEmpty)

        viewModel.toggle()
        #expect(!viewModel.isPresented)
        #expect(viewModel.searchText.isEmpty)
    }

    @Test("editor project switcher opens a real recent Ada project")
    @MainActor
    func editorProjectSwitcherOpensRecentProject() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectSwitcherOpen")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let projectURL = rootURL.appendingPathComponent("SwitchTarget", isDirectory: true)
        try createSwiftPMManifest(at: projectURL)
        _ = try ProjectSystem.createDefaultProject(at: projectURL)
        let store = EditorProjectStore(storageURL: rootURL.appendingPathComponent("projects.json"))
        let recent = EditorProjectReference(name: "SwitchTarget", path: projectURL.path)
        try store.saveProjects([recent])
        let current = EditorProjectReference(name: "CurrentGame", path: rootURL.appendingPathComponent("CurrentGame").path)
        let viewModel = EditorProjectSwitcherViewModel(currentProject: current, store: store)

        viewModel.toggle()
        let opened = try #require(viewModel.projectForOpening(recent))

        #expect(opened.path == projectURL.standardizedFileURL.path)
        #expect(!viewModel.isPresented)
        #expect(try store.loadProjects().first?.path == projectURL.standardizedFileURL.path)
    }

    @Test("create blank template requires explicit location before editor handoff")
    @MainActor
    func projectOpeningViewModelRequiresLocationBeforeCreate() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectViewModelRequiresLocation")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let storageURL = rootURL.appendingPathComponent("projects.json")
        let store = EditorProjectStore(storageURL: storageURL)
        let viewModel = ProjectOpeningViewModel(store: store)
        viewModel.projectName = "Lost Project"
        viewModel.beginCreateNewProject()

        #expect(viewModel.projectLocation.isEmpty)
        #expect(viewModel.canCreateProject == false)

        viewModel.createBlankTemplateProject()

        #expect(viewModel.detailProject == nil)
        #expect(viewModel.projectToOpenInEditor == nil)
        #expect(viewModel.projectToOpenInEditorToken == 0)
        #expect(viewModel.statusMessage == "Choose a project name and location before creating.")
        #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Lost-Project.adaproject", isDirectory: true).path) == false)
    }

    @Test("create blank template creates project and requests editor handoff")
    @MainActor
    func projectOpeningViewModelCreatesProjectForEditorHandoff() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectViewModelCreateHandoff")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let storageURL = rootURL.appendingPathComponent("projects.json")
        let store = EditorProjectStore(storageURL: storageURL)
        let viewModel = ProjectOpeningViewModel(store: store)
        viewModel.projectName = "Editor Flow"
        viewModel.setProjectLocation(rootURL)

        viewModel.createBlankTemplateProject()

        let projectURL = rootURL.appendingPathComponent(EditorProjectStore.defaultUsesProjectPackage ? "Editor-Flow.adaproject" : "Editor-Flow", isDirectory: true)
        #expect(viewModel.detailProject?.path == projectURL.standardizedFileURL.path)
        #expect(viewModel.projectToOpenInEditor?.path == projectURL.standardizedFileURL.path)
        #expect(viewModel.projectToOpenInEditorToken == 1)
        #expect(ProjectSystem.isAdaProject(at: projectURL))
        let sourcesURL = projectURL.appendingPathComponent("Sources", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("Package.swift").path))
        #expect(!FileManager.default.fileExists(atPath: sourcesURL.appendingPathComponent("AdaRuntimeBootstrap.swift").path))
        #expect(FileManager.default.fileExists(atPath: sourcesURL.appendingPathComponent("Main.ada").path))
        #expect(try ProjectSystem.loadProject(at: projectURL).build.system == .adaScript)

        let handoffProject = try #require(viewModel.consumeProjectToOpenInEditor())
        #expect(handoffProject.path == projectURL.standardizedFileURL.path)
        #expect(viewModel.projectToOpenInEditor == nil)
    }

    @Test("editor view model imports assets into project assets directory")
    @MainActor
    func editorViewModelImportsAssets() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorAssetImport")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let store = EditorProjectStore(storageURL: rootURL.appendingPathComponent("projects.json"))
        let project = try store.createProject(named: "Asset Game", at: rootURL)
        let projectURL = URL(fileURLWithPath: project.path, isDirectory: true)
        let sourceAssetURL = rootURL.appendingPathComponent("player.png", isDirectory: false)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceAssetURL)

        let viewModel = EditorViewModel(project: project)
        viewModel.importAssets(from: [sourceAssetURL])

        #expect(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("Assets/player.png").path))
        #expect(viewModel.projectSidebar.items.contains { $0.relativePath == "Assets/player.png" && $0.kind == .image })
        #expect(EditorViewModel.assetReference(for: "Assets/player.png") == "@res://player.png")
    }

    @Test("launcher layout matches design and fits minimum window")
    func projectOpeningLayoutFitsMinimumWindow() {
        #expect(ProjectOpeningLayout.windowWidth == 1024)
        #expect(ProjectOpeningLayout.windowHeight == 700)
        #expect(ProjectOpeningLayout.columnsWidth == ProjectOpeningLayout.windowWidth)
        #expect(ProjectOpeningLayout.detailContentWidth == 560)
        #expect(ProjectOpeningLayout.trafficLightOffsetY == 8)
        #expect(ProjectOpeningLayout.logoTopPadding > ProjectOpeningLayout.trafficLightOffsetY)
        #expect(ProjectOpeningAssets.adaEngineLogoResourceName == "AdaEngine")
        #expect(ProjectOpeningAssets.adaEngineLogoSubdirectory == "Assets")
        #expect(ProjectOpeningLayout.fixedDetailContentHeight <= ProjectOpeningLayout.windowHeight - ProjectOpeningLayout.detailPadding * 2)
        #expect(ProjectOpeningWindowConfiguration.isResizable == true)
        #expect(ProjectOpeningWindowConfiguration.hasShadow == true)
        #expect(ProjectOpeningLayout.detailActionButtonCount == 0)
        #expect(ProjectOpeningLayout.searchUsesGradient == false)
        #expect(ProjectOpeningLayout.searchCapsuleWidth == ProjectOpeningLayout.explorerWidth - 32)
        #expect(ProjectOpeningLayout.searchCapsuleHeight < ProjectOpeningLayout.actionButtonHeight)
        #expect(ProjectOpeningLayout.searchBottomPadding == 12)
        #expect(ProjectOpeningLayout.usesNavigationSplitView == false)
        #expect(ProjectOpeningLayout.detailUsesSearchable == false)
    }

    @Test("empty project landing exposes logo and required actions")
    func emptyProjectLandingSpecMatchesRequestedActions() {
        #expect(ProjectOpeningLandingSpec.primaryButtonTitles == ["Create new project", "Open project"])
        #expect(ProjectOpeningLandingSpec.footerButtonTitles == ["Report issues", "Support", "Github"])
        #expect(ProjectOpeningLandingSpec.logoSize == 128)
        #expect(ProjectOpeningLandingSpec.primaryButtonWidth > ProjectOpeningLandingSpec.logoSize)
        #expect(ProjectOpeningLandingSpec.primaryButtonHeight > ProjectOpeningLandingSpec.footerButtonHeight)
        #expect(ProjectOpeningLandingSpec.footerButtonHeight < ProjectOpeningLayout.actionButtonHeight)
    }

    @Test("AdaEngineStyle UI layout matches requested reference")
    func editorGlassLayoutMatchesRequestedReference() {
        #expect(AdaEngineStyleLayoutSpec.windowWidth == 1280)
        #expect(AdaEngineStyleLayoutSpec.windowHeight == 820)
        #expect(AdaEngineStyleLayoutSpec.topToolbarHeight == 40)
        #expect(AdaEngineStyleLayoutSpec.toolStripWidth == 40)
        #expect(AdaEngineStyleLayoutSpec.projectSidebarWidth == 260)
        #expect(AdaEngineStyleLayoutSpec.inspectorWidth == 300)
        #expect(AdaEngineStyleLayoutSpec.outputPanelHeight == 42)
        #expect(AdaEngineStyleLayoutSpec.footerHeight == 24)
        #expect(AdaEngineStyleLayoutSpec.aiFlightBoxWidth == 560)
        #expect(AdaEngineStyleContent.logLines.count == 4)
    }

    @Test("project open picker resolves selected package manifest to project directory")
    func projectOpenPickerResolvesManifestToProjectDirectory() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "ProjectOpenPickerManifest")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let manifestURL = rootURL.appendingPathComponent("Package.swift", isDirectory: false)
        try "// swift-tools-version: 6.2\n".write(to: manifestURL, atomically: true, encoding: .utf8)

        #expect(ProjectOpenPicker.projectDirectoryURL(fromPickerSelection: manifestURL) == rootURL.standardizedFileURL)
    }

    @Test("project open picker keeps selected directory as project directory")
    func projectOpenPickerKeepsSelectedDirectory() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "ProjectOpenPickerDirectory")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        #expect(ProjectOpenPicker.projectDirectoryURL(fromPickerSelection: rootURL) == rootURL.standardizedFileURL)
    }

    @Test("project location picker resolves files to their containing directory")
    func projectLocationPickerResolvesFilesToContainingDirectory() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "ProjectLocationPickerFile")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let fileURL = rootURL.appendingPathComponent("note.txt", isDirectory: false)
        try "location".write(to: fileURL, atomically: true, encoding: .utf8)

        #expect(ProjectOpenPicker.projectLocationURL(fromPickerSelection: fileURL) == rootURL.standardizedFileURL)
    }

    @Test("view model opens project from picked URL and requests editor handoff")
    @MainActor
    func projectOpeningViewModelOpensPickedProjectURL() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectViewModelPickedURL")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let storageURL = rootURL.appendingPathComponent("projects.json")
        let store = EditorProjectStore(storageURL: storageURL)
        let projectURL = rootURL.appendingPathComponent("PickedProject", isDirectory: true)
        try createSwiftPMManifest(at: projectURL)
        _ = try ProjectSystem.createDefaultProject(at: projectURL)

        let viewModel = ProjectOpeningViewModel(store: store)
        viewModel.openProject(at: projectURL)

        #expect(viewModel.existingProjectPath == projectURL.path)
        #expect(viewModel.detailProject?.path == projectURL.standardizedFileURL.path)
        #expect(viewModel.projectToOpenInEditor?.path == projectURL.standardizedFileURL.path)
        #expect(viewModel.projectToOpenInEditorToken == 1)
        #expect(viewModel.statusMessage.hasPrefix("Opened project:"))
    }

    @Test("incoming project URL is buffered until the opening view model is ready")
    @MainActor
    func incomingProjectURLIsBufferedUntilOpeningViewModelIsReady() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorIncomingProjectURL")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let store = EditorProjectStore(storageURL: rootURL.appendingPathComponent("projects.json"))
        let project = try store.createProject(named: "Incoming", at: rootURL, template: .adaScript)
        let projectURL = URL(fileURLWithPath: project.path, isDirectory: true)
        let viewModel = ProjectOpeningViewModel(store: store)
        let notificationName = Notification.Name("AdaEditorTests.IncomingProjectURL")
        let notificationCenter = NotificationCenter()
        let router = EditorProjectOpenURLRouter(
            notificationCenter: notificationCenter,
            notificationName: notificationName
        )

        notificationCenter.post(name: notificationName, object: projectURL)
        #expect(viewModel.projectToOpenInEditor == nil)

        #expect(router.attach(viewModel))
        #expect(viewModel.projectToOpenInEditor?.path == projectURL.standardizedFileURL.path)
        #expect(viewModel.projectToOpenInEditorToken == 1)
    }

    @Test("incoming project URL reaches an already active opening view model")
    @MainActor
    func incomingProjectURLReachesActiveOpeningViewModel() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorRunningProjectURL")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let store = EditorProjectStore(storageURL: rootURL.appendingPathComponent("projects.json"))
        let project = try store.createProject(named: "Running", at: rootURL, template: .adaScript)
        let projectURL = URL(fileURLWithPath: project.path, isDirectory: true)
        let viewModel = ProjectOpeningViewModel(store: store)
        let notificationName = Notification.Name("AdaEditorTests.RunningProjectURL")
        let notificationCenter = NotificationCenter()
        let router = EditorProjectOpenURLRouter(
            notificationCenter: notificationCenter,
            notificationName: notificationName
        )
        #expect(!router.attach(viewModel))

        notificationCenter.post(name: notificationName, object: projectURL)

        #expect(viewModel.projectToOpenInEditor?.path == projectURL.standardizedFileURL.path)
        #expect(viewModel.projectToOpenInEditorToken == 1)
    }

    @Test("view model opens recent project and requests editor handoff")
    @MainActor
    func projectOpeningViewModelOpensRecentProjectForEditorHandoff() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectViewModelOpenRecent")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let storageURL = rootURL.appendingPathComponent("projects.json")
        let store = EditorProjectStore(storageURL: storageURL)
        let projectURL = rootURL.appendingPathComponent("RecentProject", isDirectory: true)
        try createSwiftPMManifest(at: projectURL)
        _ = try ProjectSystem.createDefaultProject(at: projectURL)
        let recentProject = EditorProjectReference(name: "RecentProject", path: projectURL.standardizedFileURL.path)
        try store.saveProjects([recentProject])

        let viewModel = ProjectOpeningViewModel(store: store)
        viewModel.openRecentProject(recentProject)

        #expect(viewModel.detailProject?.path == projectURL.standardizedFileURL.path)
        #expect(viewModel.projectToOpenInEditor?.path == projectURL.standardizedFileURL.path)
        #expect(viewModel.projectToOpenInEditorToken == 1)
        #expect(viewModel.statusMessage.hasPrefix("Opened project:"))
    }

    @Test("view model opens last available project on launch")
    @MainActor
    func projectOpeningViewModelOpensLastAvailableProjectOnLaunch() async throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectViewModelOpenLast")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let storageURL = rootURL.appendingPathComponent("projects.json")
        let store = EditorProjectStore(storageURL: storageURL)
        let olderProjectURL = rootURL.appendingPathComponent("OlderProject", isDirectory: true)
        let latestProjectURL = rootURL.appendingPathComponent("LatestProject", isDirectory: true)
        try createSwiftPMManifest(at: olderProjectURL)
        try ProjectSystem.createDefaultProject(at: olderProjectURL)
        try createSwiftPMManifest(at: latestProjectURL)
        try ProjectSystem.createDefaultProject(at: latestProjectURL)

        let olderDate = try #require(ISO8601DateFormatter().date(from: "2026-02-19T10:00:00Z"))
        let latestDate = try #require(ISO8601DateFormatter().date(from: "2026-02-20T10:00:00Z"))
        try store.saveProjects([
            EditorProjectReference(name: "OlderProject", path: olderProjectURL.standardizedFileURL.path, lastOpenedAt: olderDate),
            EditorProjectReference(name: "LatestProject", path: latestProjectURL.standardizedFileURL.path, lastOpenedAt: latestDate),
        ])

        let viewModel = ProjectOpeningViewModel(store: store)
        let didOpen = await viewModel.openLastProjectIfAvailable()

        #expect(didOpen)
        #expect(viewModel.detailProject?.path == latestProjectURL.standardizedFileURL.path)
        #expect(viewModel.projectToOpenInEditor?.path == latestProjectURL.standardizedFileURL.path)
        #expect(viewModel.projectToOpenInEditorToken == 1)
        #expect(viewModel.statusMessage.hasPrefix("Opened project:"))
    }

    @Test("view model leaves welcome visible when last project is missing")
    @MainActor
    func projectOpeningViewModelSkipsMissingLastProjectOnLaunch() async throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectViewModelMissingLast")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }

        let storageURL = rootURL.appendingPathComponent("projects.json")
        let store = EditorProjectStore(storageURL: storageURL)
        let missingProjectURL = rootURL.appendingPathComponent("MissingProject", isDirectory: true)
        try store.saveProjects([
            EditorProjectReference(name: "MissingProject", path: missingProjectURL.standardizedFileURL.path)
        ])

        let viewModel = ProjectOpeningViewModel(store: store)
        let didOpen = await viewModel.openLastProjectIfAvailable()

        #expect(!didOpen)
        #expect(viewModel.detailProject == nil)
        #expect(viewModel.projectToOpenInEditor == nil)
        #expect(viewModel.projectToOpenInEditorToken == 0)
        #expect(viewModel.statusMessage.hasPrefix("Last project is no longer available:"))
    }

    @Test("create project refuses to overwrite a non-empty destination")
    func createProjectRefusesNonEmptyDestination() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectStoreExistingDestination")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }
        let projectURL = rootURL.appendingPathComponent("Existing", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let sentinelURL = projectURL.appendingPathComponent("sentinel.txt")
        try "keep".write(to: sentinelURL, atomically: true, encoding: .utf8)
        let store = EditorProjectStore(storageURL: rootURL.appendingPathComponent("projects.json"))

        #expect(throws: EditorProjectStoreError.projectDirectoryNotEmpty(path: projectURL.path)) {
            try store.createProject(named: "Existing", at: rootURL)
        }
        #expect(try String(contentsOf: sentinelURL, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("Package.swift").path))
    }

    @Test("dependency operations mutate the project Package.swift and normalize identities")
    func dependencyOperationsMutateManifest() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectStoreDependencies")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }
        let engineURL = rootURL.appendingPathComponent("Engine", isDirectory: true)
        let store = EditorProjectStore(
            storageURL: rootURL.appendingPathComponent("projects.json"),
            adaEnginePackageURL: engineURL
        )
        let reference = try store.createProject(named: "Game", at: rootURL)
        let projectURL = URL(fileURLWithPath: reference.path, isDirectory: true)

        #expect(try store.addDependency(to: projectURL, url: "https://example.com/My_Library.git", requirement: #"from: "1.0.0""#))
        #expect(try store.removeDependency(from: projectURL, identity: "my-library"))
        let manifest = try String(contentsOf: projectURL.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(!manifest.contains("My_Library.git"))
        #expect(manifest.contains(engineURL.path))
        #expect(manifest.contains(#".product(name: "AdaEngine", package: "AdaEngine")"#))
    }

    @Test("invalid remote dependency input never changes Package.swift")
    func invalidDependencyDoesNotChangeManifest() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectStoreInvalidDependency")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }
        let store = EditorProjectStore(storageURL: rootURL.appendingPathComponent("projects.json"))
        let reference = try store.createProject(named: "SafeManifestGame", at: rootURL)
        let projectURL = URL(fileURLWithPath: reference.path, isDirectory: true)
        let manifestURL = projectURL.appendingPathComponent("Package.swift")
        let originalManifest = try String(contentsOf: manifestURL, encoding: .utf8)

        for (url, requirement) in [
            ("https://example.com/lib.git", ""),
            ("https://example.com/lib.git", "from: latest"),
            ("https://example.com/\nlib.git", #"branch: "main""#),
        ] {
            do {
                _ = try store.addDependency(to: projectURL, url: url, requirement: requirement)
                Issue.record("Expected invalid dependency input to throw")
            } catch {
                #expect(try String(contentsOf: manifestURL, encoding: .utf8) == originalManifest)
            }
        }
    }

    @Test("saving project settings updates metadata and SwiftPM target")
    func saveProjectSettingsSynchronizesManifest() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectStoreSettings")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }
        let store = EditorProjectStore(storageURL: rootURL.appendingPathComponent("projects.json"))
        let reference = try store.createProject(named: "SettingsGame", at: rootURL)
        let projectURL = URL(fileURLWithPath: reference.path, isDirectory: true)
        var project = try ProjectSystem.loadProject(at: projectURL)
        project.paths.resourceRoots = ["Assets", "Localization"]
        project.build.includedFiles = ["Sources/SettingsGame", "Sources/Shared.swift"]
        project.build.excludedFiles = ["Sources/SettingsGame/Drafts"]
        project.run.destination = .web

        try store.saveProjectSettings(project, at: projectURL, targetName: "SettingsGame")

        #expect(try ProjectSystem.loadProject(at: projectURL) == project)
        let manifest = try String(contentsOf: projectURL.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(manifest.contains(#"sources: ["Sources/SettingsGame", "Sources/Shared.swift"]"#))
        #expect(manifest.contains(#"exclude: ["Sources/SettingsGame/Drafts"]"#))
        #expect(manifest.contains(#"resources: [.copy("Assets"), .copy("Localization")]"#))
    }

    @Test("standard implicit target keeps its source root and uses a relative project resource")
    func standardTargetSettingsRemainValidSwiftPM() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectStoreStandardTarget")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }
        let projectURL = rootURL.appendingPathComponent("StandardGame", isDirectory: true)
        let sourcesURL = projectURL.appendingPathComponent("Sources/Game", isDirectory: true)
        let assetsURL = projectURL.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try "print(\"game\")\n".write(to: sourcesURL.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "asset\n".write(to: assetsURL.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.2
        import PackageDescription

        let package = Package(
            name: "StandardGame",
            products: [.executable(name: "Game", targets: ["Game"])],
            dependencies: [],
            targets: [.executableTarget(name: "Game", dependencies: [])]
        )
        """
        .write(to: projectURL.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        var project = try ProjectSystem.createDefaultProject(at: projectURL)
        project.paths.resourceRoots = ["Assets"]
        let store = EditorProjectStore(storageURL: rootURL.appendingPathComponent("projects.json"))

        try store.saveProjectSettings(project, at: projectURL, targetName: "Game")

        let manifest = try String(contentsOf: projectURL.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(!manifest.contains(#"path: ".""#))
        #expect(!manifest.contains("\n            sources:"))
        #expect(manifest.contains(#"resources: [.copy("../../Assets")]"#))
        let dumpResult = try runSwiftPackageDump(at: projectURL)
        #expect(dumpResult.status == 0, Comment(rawValue: dumpResult.error))
    }

    @Test("editor run destination loads from and persists to project settings")
    @MainActor
    func editorRunDestinationPersists() throws {
        let rootURL = try makeEditorStoreTemporaryDirectory(named: "EditorProjectStoreRunDestination")
        defer { removeEditorStoreTemporaryDirectory(rootURL) }
        let store = EditorProjectStore(storageURL: rootURL.appendingPathComponent("projects.json"))
        let reference = try store.createProject(named: "RunDestinationGame", at: rootURL)
        let projectURL = URL(fileURLWithPath: reference.path, isDirectory: true)

        let viewModel = EditorViewModel(project: reference)
        #expect(viewModel.selectedRunDestination == .macOS)
        viewModel.selectRunDestination(.web)

        #expect(viewModel.selectedRunDestination == .web)
        #expect(try ProjectSystem.loadProject(at: projectURL).run.destination == .web)
    }
}

private func makeEditorStoreTemporaryDirectory(named name: String? = nil) throws -> URL {
    let directoryName = name ?? "EditorProjectStoreTests-\(UUID().uuidString)"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func removeEditorStoreTemporaryDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func adaEnginePackageURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .standardizedFileURL
}

private func createSwiftPMManifest(at projectURL: URL) throws {
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let targetName = projectURL.lastPathComponent.replacingOccurrences(of: "-", with: "_")
    try """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "\(projectURL.lastPathComponent)",
        products: [.executable(name: "\(targetName)", targets: ["\(targetName)"])],
        dependencies: [],
        targets: [.executableTarget(name: "\(targetName)", dependencies: [])]
    )
    """
    .write(
        to: projectURL.appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8
    )
}

private func runSwiftPackageDump(at projectURL: URL) throws -> (status: Int32, error: String) {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "package", "--disable-sandbox", "dump-package"]
    process.currentDirectoryURL = projectURL
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(bytes: errorData, encoding: .utf8) ?? "")
}
