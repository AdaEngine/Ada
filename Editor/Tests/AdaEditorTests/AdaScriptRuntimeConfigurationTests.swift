import Foundation
import Testing

@testable import AdaEditor

@Suite("AdaScript runtime configuration")
struct AdaScriptRuntimeConfigurationTests {
    @Test("schema v2 entry fields migrate into the runtime entry plan")
    func legacyEntryFieldsDecode() throws {
        let project = try ProjectSystem.loadProject(
            from: Data(
                #"{"schemaVersion":2,"build":{"system":"adascript"},"runtime":{"moduleName":"Game","entryView":"game.hud","startupScene":"Assets/Scenes/Main.ascn"}}"#.utf8
            )
        )

        #expect(
            project.runtime.entry
                == AdaProjectRuntimeEntry(
                    scene: "Assets/Scenes/Main.ascn",
                    view: "game.hud"
                )
        )
        #expect(project.runtime.plugins.preset == .game2D)
    }

    @Test("saving a schema v2 project writes one normalized schema v3 runtime")
    func legacyProjectSavesAsSchemaV3() throws {
        let fileManager = FileManager.default
        let projectURL = fileManager.temporaryDirectory
            .appendingPathComponent("AdaScriptSchemaUpgrade-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: projectURL) }
        let project = try ProjectSystem.loadProject(
            from: Data(
                #"{"schemaVersion":2,"build":{"system":"adascript"},"runtime":{"moduleName":"Game","entryView":"game.hud"}}"#.utf8
            )
        )

        try ProjectSystem.saveProject(project, at: projectURL, fileManager: fileManager)

        let saved = try String(
            contentsOf: ProjectSystem.metadataURL(forProjectAt: projectURL),
            encoding: .utf8
        )
        #expect(saved.contains(#""schemaVersion" : 3"#))
        #expect(saved.contains(#""entry""#))
        #expect(!saved.contains(#""entryView""#))
    }

    @Test("plugin resolver applies presets overrides and dependencies")
    func resolvesPluginGraph() throws {
        let configuration = AdaProjectRuntimePlugins(
            preset: .ui,
            enable: [.tilemap]
        )

        let resolved = try EditorAdaScriptRuntimePluginResolver.resolve(configuration)

        #expect(resolved.pluginIDs == [.core2D, .sprite, .mesh2D, .tilemap, .upscale])
    }

    @Test("plugin settings sections cover every catalog plugin once")
    func pluginSettingsSectionsCoverCatalog() {
        let sectionPluginIDs = EditorAdaScriptRuntimePluginCatalog.settingsSections
            .flatMap(\.allPluginIDs)

        #expect(Set(sectionPluginIDs) == Set(EditorAdaScriptRuntimePluginCatalog.descriptors.map(\.id)))
        #expect(Set(sectionPluginIDs).count == sectionPluginIDs.count)
    }

    @Test("plugin resolver rejects a disabled dependency")
    func rejectsDisabledDependency() {
        let configuration = AdaProjectRuntimePlugins(
            preset: .ui,
            enable: [.tilemap],
            disable: [.sprite]
        )

        #expect(
            throws: EditorRuntimePluginResolutionError.disabledDependency(
                plugin: "sprite",
                requiredBy: "tilemap"
            )
        ) {
            try EditorAdaScriptRuntimePluginResolver.resolve(configuration)
        }
    }

    @Test("scene-only project builds without a root view")
    @MainActor
    func sceneOnlyProjectBuilds() throws {
        let fileManager = FileManager.default
        let projectURL = fileManager.temporaryDirectory
            .appendingPathComponent("AdaScriptSceneOnly-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: projectURL) }
        let sourcesURL = projectURL.appendingPathComponent("Sources", isDirectory: true)
        let scenesURL = projectURL.appendingPathComponent("Assets/Scenes", isDirectory: true)
        try fileManager.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scenesURL, withIntermediateDirectories: true)
        try "func helper() { return 1; }"
            .write(
                to: sourcesURL.appendingPathComponent("Main.ada"),
                atomically: true,
                encoding: .utf8
            )
        try SceneDocumentFormat.defaultSceneYAML(projectName: "SceneOnly")
            .write(
                to: scenesURL.appendingPathComponent("Main.ascn"),
                atomically: true,
                encoding: .utf8
            )
        var project = ProjectSystem.defaultProject(projectName: "SceneOnly", buildSystem: .adaScript)
        project.runtime.entry.view = nil

        let artifact = try EditorAdaScriptProjectBuilder(fileManager: fileManager)
            .prepare(
                project: project,
                at: projectURL
            )

        #expect(artifact.entry.view == nil)
        #expect(artifact.sceneModel != nil)
        #expect(artifact.report.entryDescription == "scene Assets/Scenes/Main.ascn")
    }

    @Test("missing entry view offers the runtime entry settings page")
    @MainActor
    func missingEntryViewOffersRuntimeSettings() {
        let action = EditorViewModel.notificationAction(
            for: .entryViewMissing(identifier: "game.main"),
            projectID: "mobius"
        )

        #expect(
            action
                == EditorNotificationAction(
                    title: "Open Runtime Entry",
                    destination: .projectSettings,
                    projectID: "mobius",
                    settingsPage: EditorSettingsPage.runtimeEntry
                )
        )
    }

    @Test("settings draft persists entry plugins physics and window")
    @MainActor
    func settingsDraftPersistsRuntime() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("AdaScriptRuntimeSettings-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        let reference = try EditorProjectStore(
            storageURL: rootURL.appendingPathComponent("projects.json")
        )
        .createProject(named: "ConfiguredGame", at: rootURL, template: .adaScript)
        let editorViewModel = EditorViewModel(project: reference, fileManager: fileManager)
        let settingsViewModel = EditorSettingsWindowViewModel(
            editorViewModel: editorViewModel,
            selectedSection: .project
        )
        let alternateScenePath = "Assets/Scenes/Opening.ascn"
        try SceneDocumentFormat.defaultSceneYAML(projectName: "Opening")
            .write(
                to: URL(fileURLWithPath: reference.path, isDirectory: true).appendingPathComponent(alternateScenePath),
                atomically: true,
                encoding: .utf8
            )
        editorViewModel.projectDisplayNameText = "Configured Game"
        editorViewModel.projectBundleIdentifierText = "dev.adaengine.configured-game"
        editorViewModel.projectMainSceneText = alternateScenePath
        settingsViewModel.runtimeSettings.plugins.preset = .game3D
        settingsViewModel.runtimeSettings.plugins.enable = [.physics2D]
        settingsViewModel.runtimeDraft.view = "game.main"
        settingsViewModel.runtimeDraft.gravityX = "1.5"
        settingsViewModel.runtimeDraft.gravityY = "-12"
        settingsViewModel.runtimeDraft.windowTitle = "Configured Runtime"
        settingsViewModel.runtimeDraft.windowWidth = "1440"
        settingsViewModel.runtimeDraft.windowHeight = "900"

        settingsViewModel.toggleRuntimePlugin(.upscale)
        #expect(settingsViewModel.isRuntimePluginEnabled(.upscale))
        #expect(settingsViewModel.runtimeSettingsStatusMessage.contains("required by"))

        settingsViewModel.saveProjectSettings()

        let saved = try ProjectSystem.loadProject(
            at: URL(fileURLWithPath: reference.path, isDirectory: true),
            fileManager: fileManager
        )
        #expect(saved.runtime.plugins.preset == .game3D)
        #expect(saved.runtime.plugins.enable == [.physics2D])
        #expect(saved.runtime.plugins.settings.physics2D.gravity == [1.5, -12])
        #expect(saved.runtime.window.title == "Configured Runtime")
        #expect(saved.runtime.window.size == AdaProjectRuntimeWindowSize(width: 1440, height: 900))
        #expect(saved.project.displayName == "Configured Game")
        #expect(saved.project.bundleIdentifier == "dev.adaengine.configured-game")
        #expect(saved.editor.startupScene == alternateScenePath)
        #expect(saved.runtime.entry.scene == alternateScenePath)

        let artifact = try EditorAdaScriptProjectBuilder(fileManager: fileManager)
            .prepare(
                project: saved,
                at: URL(fileURLWithPath: reference.path, isDirectory: true)
            )
        #expect(artifact.report.startupScene == alternateScenePath)
        #expect(artifact.report.entryDescription.contains("scene \(alternateScenePath)"))
    }
}
