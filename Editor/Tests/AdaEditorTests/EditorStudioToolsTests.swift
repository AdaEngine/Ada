@_spi(AdaEngine) import AdaEngine
import AdaScriptCompilerCore
import Foundation
import Testing

@testable import AdaEditor

@Suite("Studio .ui tools", .serialized)
@MainActor
struct EditorStudioToolsTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "Studio tool tests")))
        }
    }
    @Test func panelActionUsesRealVMAndSceneHistory() async throws {
        let fixture = try makeFixture()
        defer {
            fixture.host.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        allow(fixture.host, "studio.level-helper")
        #expect(fixture.host.error == nil)
        let panel = try #require(fixture.host.selectedPanel)
        #expect(panel.runtime.schema.fields.map(\.name) == ["count", "status"])
        #expect(panel.session.context.value("count") == .number(3))
        panel.session.context.set("count", to: .number(5))
        let previousSelection = fixture.editor.workbench.activeSceneDocument?.sceneModel?.editor
        let container = UIContainerView(rootView: UISceneView(session: panel.session).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 340, height: 600)
        container.layoutSubviews()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("studio.level-helper.generate"))
        for _ in 0..<20 { await Task.yield() }
        #expect(panel.error == nil)
        #expect(fixture.editor.workbench.activeSceneDocument?.sceneModel?.entities.count == fixture.count + 5)
        #expect(fixture.editor.workbench.activeSceneDocument?.isDirty == true)
        #expect(fixture.editor.workbench.activeSceneDocument?.sceneModel?.editor == previousSelection)
        #expect(panel.session.context.value("status")?.string?.contains("Generated") == true)
        #expect(fixture.editor.workbench.performDocumentHistory(redo: false))
        #expect(fixture.editor.workbench.activeSceneDocument?.sceneModel?.entities.count == fixture.count)
        #expect(fixture.editor.workbench.performDocumentHistory(redo: true))
        #expect(fixture.editor.workbench.saveActiveDocument())
        let saved = try String(contentsOf: fixture.root.appendingPathComponent("Assets/Main.ascn"), encoding: .utf8)
        #expect(try EditorSceneModel.decode(from: saved).entities.count == fixture.count + 5)
    }

    @Test func permissionDialogMustBeApprovedBeforeToolUIAppears() async throws {
        let fixture = try makeFixture()
        defer {
            fixture.host.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        fixture.host.reviewAvailableTools()
        #expect(fixture.host.permissionRequest != nil)
        #expect(fixture.host.panels.isEmpty)
        let container = UIContainerView(
            rootView: EditorStudioToolsSidebar(host: fixture.host)
                .modifier(EditorStudioToolPermissionPresentation(host: fixture.host, presentation: .workspace)).theme(.adaEditor)
        )
        container.frame = Rect(x: 0, y: 0, width: 800, height: 680)
        container.layoutSubviews()
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("studio.level-helper.generate")).isEmpty)
        _ = try container.uiNode(matching: .accessibilityIdentifier("studio.tools.permissions.dialog"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("studio.tools.permissions.allow"))
        #expect(fixture.host.error == nil)
        #expect(fixture.host.panels.count == 1)
        #expect(fixture.host.permissionRequest == nil)
        for _ in 0..<30 {
            await Task.yield()
            container.update(1 / 30)
        }
        container.layoutSubviews()
        #expect(try container.uiNode(matching: .accessibilityIdentifier("studio.level-helper.generate")).absoluteFrame.height > 0)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("studio.tools.disable.studio.level-helper")).isEmpty)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("studio.tools.enable.studio.level-helper")).isEmpty)
    }

    @Test func settingsRevokeAccessAndDoNotPromptAgainOnReload() async throws {
        let fixture = try makeFixture()
        defer {
            fixture.host.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        allow(fixture.host, "studio.level-helper")
        let panel = try #require(fixture.host.selectedPanel)
        panel.session.context.perform("generate")
        let container = UIContainerView(rootView: EditorStudioToolsSettings(host: fixture.host).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 640, height: 500)
        container.layoutSubviews()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("studio.tools.revoke.studio.level-helper"))
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.host.panels.isEmpty)
        #expect(fixture.editor.workbench.activeSceneDocument?.sceneModel?.entities.count == fixture.count)
        fixture.host.reload()
        fixture.host.reviewAvailableTools()
        #expect(fixture.host.permissionRequest == nil)
        fixture.host.enable("studio.level-helper", presentation: .settings)
        #expect(fixture.host.permissionRequest?.presentation == .settings)
        #expect(fixture.host.panels.isEmpty)
    }

    @Test func cancelledOrStaleConsentNeverActivatesTool() throws {
        let fixture = try makeFixture()
        defer {
            fixture.host.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        fixture.host.enable("studio.level-helper")
        let cancelled = try #require(fixture.host.permissionRequest)
        fixture.host.cancelPermissionRequest(cancelled.id)
        fixture.host.approve(cancelled.id)
        #expect(fixture.host.panels.isEmpty)
        #expect(fixture.host.reviewCandidateIDs.isEmpty)
        fixture.host.enable("studio.level-helper")
        let stale = try #require(fixture.host.permissionRequest)
        let source = fixture.root.appendingPathComponent("Tools/LevelHelper/LevelHelper.ada")
        let text = try String(contentsOf: source, encoding: .utf8)
        try text.replacingOccurrences(of: "version: \"1.0.0\"", with: "version: \"1.1.0\"").write(to: source, atomically: true, encoding: .utf8)
        fixture.host.reload()
        fixture.host.approve(stale.id)
        #expect(fixture.host.panels.isEmpty)
        #expect(fixture.host.error != nil)
    }

    @Test func selectionRefreshRetainsToolsUntilInspectorIsExplicitlyOpened() throws {
        let fixture = try makeFixture()
        defer {
            fixture.host.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        fixture.editor.toolStrip.activeRightTool = "studioTools"
        fixture.editor.showRightPanel = true
        fixture.editor.presentSceneInspectorForSelection()
        #expect(fixture.editor.toolStrip.activeRightTool == "studioTools")
        #expect(fixture.editor.showRightPanel)
        #expect(fixture.editor.handleMenuCommand(.showInspector))
        #expect(fixture.editor.toolStrip.activeRightTool == "inspector")
    }

    @Test func disableRemovesPanelsAndQueuedActions() async throws {
        let fixture = try makeFixture()
        defer {
            fixture.host.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        allow(fixture.host, "studio.level-helper")
        let old = try #require(fixture.host.selectedPanel)
        old.session.context.perform("generate")
        fixture.host.disable("studio.level-helper")
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.host.panels.isEmpty)
        #expect(fixture.editor.workbench.activeSceneDocument?.sceneModel?.entities.count == fixture.count)
        old.session.context.perform("generate")
        allow(fixture.host, "studio.level-helper")
        #expect(fixture.host.panels.count == 1)
        allow(fixture.host, "studio.level-helper")
        #expect(fixture.host.panels.count == 1)
    }

    @Test func reloadRetainsInputsAndRejectsInvalidUIAndSource() throws {
        let fixture = try makeFixture()
        defer {
            fixture.host.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        allow(fixture.host, "studio.level-helper")
        let old = try #require(fixture.host.selectedPanel)
        old.session.context.set("count", to: .number(7))
        let ui = fixture.root.appendingPathComponent("Tools/LevelHelper/LevelHelper.ui")
        let content = try String(contentsOf: ui, encoding: .utf8)
        try content.replacingOccurrences(of: "value: Generate", with: "value: Generate entities").write(to: ui, atomically: true, encoding: .utf8)
        fixture.host.reload()
        let updated = try #require(fixture.host.selectedPanel)
        #expect(updated.session.context.value("count") == .number(7))
        #expect(updated.runtime === old.runtime)
        #expect(old.isRetired)
        try "invalid: [".write(to: ui, atomically: true, encoding: .utf8)
        fixture.host.reload()
        #expect(fixture.host.selectedPanel === updated)
        #expect(fixture.host.error != nil)
        try content.write(to: ui, atomically: true, encoding: .utf8)
        let source = fixture.root.appendingPathComponent("Tools/LevelHelper/LevelHelper.ada")
        try "@tool(id: \"studio.level-helper\") class LevelHelper {".write(to: source, atomically: true, encoding: .utf8)
        fixture.host.reload()
        #expect(fixture.host.selectedPanel === updated)
        #expect(fixture.host.error != nil)
    }

    @Test func revokedAndUnsupportedPermissionsNeverExecute() throws {
        let source = AdaScriptCompilerSource(
            path: "Tool.ada",
            source: """
                @tool(id: "readonly", permissions: ["editor.documents.read"])
                class ReadOnly {
                    func activate(editor) { editor.addPanel("panel", "Panel", "right", "Panel.ui"); }
                    func edit(editor) { editor.createEntity("Denied", 0.0, 0.0); }
                }
                """
        )
        let schema = try #require(AdaScriptSchemaParser.parseTools(sources: [source]).first)
        #expect(throws: AdaScriptError.self) { try AdaScriptToolRuntime(sources: [source], schema: schema, grantedPermissions: []) }
        let runtime = try AdaScriptToolRuntime(sources: [source], schema: schema, grantedPermissions: [.documentRead])
        try runtime.activate()
        #expect(throws: AdaScriptError.self) {
            try runtime.perform("edit", inputs: [:], scene: .init(path: "Main.ascn", revision: "1", entityCount: 0))
        }
        runtime.deactivate()
        #expect(throws: AdaScriptError.self) { try runtime.perform("edit", inputs: [:], scene: nil) }
    }

    @Test func infiniteCallbacksStopAndPendingEditsAreDiscarded() throws {
        let source = AdaScriptCompilerSource(
            path: "Loop.ada",
            source: """
                @tool(id: "loop", permissions: ["editor.documents.write"])
                class Loop {
                    func activate(editor) { editor.addPanel("panel", "Panel", "right", "Panel.ui"); }
                    func run(editor) { editor.createEntity("Never committed", 0.0, 0.0); while (true) {} }
                }
                """
        )
        let schema = try #require(AdaScriptSchemaParser.parseTools(sources: [source]).first)
        let runtime = try AdaScriptToolRuntime(sources: [source], schema: schema, grantedPermissions: [.documentWrite])
        try runtime.activate()
        let start = ContinuousClock.now
        #expect(throws: AdaScriptError.self) { try runtime.perform("run", inputs: [:], scene: .init(path: "Main.ascn", revision: "1", entityCount: 0)) }
        #expect(start.duration(to: .now) < .seconds(2))
        runtime.deactivate()
    }

    @Test func changedSceneRejectsQueuedWrite() async throws {
        let fixture = try makeFixture()
        defer {
            fixture.host.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        allow(fixture.host, "studio.level-helper")
        let panel = try #require(fixture.host.selectedPanel)
        panel.session.context.perform("generate")
        var document = try #require(fixture.editor.workbench.activeSceneDocument)
        document.content += "\n# edited before the queued action\n"
        fixture.editor.workbench.replaceSceneDocument(document)
        for _ in 0..<20 { await Task.yield() }
        #expect(panel.error != nil)
        #expect(fixture.editor.workbench.activeSceneDocument?.sceneModel?.entities.count == fixture.count)
    }

    @Test func permissionChangesRequireEnableAgain() throws {
        let fixture = try makeFixture()
        defer {
            fixture.host.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        allow(fixture.host, "studio.level-helper")
        let source = fixture.root.appendingPathComponent("Tools/LevelHelper/LevelHelper.ada")
        let content = try String(contentsOf: source, encoding: .utf8)
        try content.replacingOccurrences(of: "\"editor.documents.read\", \"editor.documents.write\"", with: "\"network\"").write(to: source, atomically: true, encoding: .utf8)
        fixture.host.reload()
        #expect(fixture.host.panels.isEmpty)
        allow(fixture.host, "studio.level-helper")
        #expect(fixture.host.error != nil)
        #expect(fixture.host.panels.isEmpty)
    }

    @Test func outsidePanelAndDuplicateIDsAreRejected() throws {
        let fixture = try makeFixture()
        defer {
            fixture.host.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let source = fixture.root.appendingPathComponent("Tools/LevelHelper/LevelHelper.ada")
        let content = try String(contentsOf: source, encoding: .utf8)
        try content.replacingOccurrences(of: "ui: \"LevelHelper.ui\"", with: "ui: \"../../Outside.ui\"").write(to: source, atomically: true, encoding: .utf8)
        fixture.host.reload()
        allow(fixture.host, "studio.level-helper")
        #expect(fixture.host.panels.isEmpty)
        #expect(fixture.host.error != nil)
        try content.write(to: fixture.root.appendingPathComponent("Tools/LevelHelper/Duplicate.ada"), atomically: true, encoding: .utf8)
        #expect(throws: AdaScriptSchemaError.self) { try EditorStudioToolDiscovery.discover(at: fixture.root) }
    }

    @Test func projectsOwnTheirGrantsAndUnchangedReloadKeepsPanel() throws {
        let sharedDefaults = try #require(UserDefaults(suiteName: "StudioToolProjects-\(UUID())"))
        let first = try makeFixture(defaults: sharedDefaults)
        let second = try makeFixture(defaults: sharedDefaults)
        defer {
            first.host.close()
            second.host.close()
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: second.root)
        }
        allow(first.host, "studio.level-helper")
        let panel = try #require(first.host.selectedPanel)
        first.host.reload()
        #expect(first.host.selectedPanel === panel)
        #expect(second.host.panels.isEmpty)
        #expect(second.host.enabledIDs.isEmpty)
        allow(second.host, "studio.level-helper")
        #expect(second.host.selectedPanel?.runtime !== panel.runtime)
        first.host.close()
        #expect(second.host.panels.count == 1)
        let restored = EditorStudioToolHost(defaults: sharedDefaults)
        restored.open(projectURL: first.root, editor: first.editor)
        #expect(restored.panels.count == 1)
        #expect(restored.enabledIDs.contains("studio.level-helper"))
        restored.close()
    }

    @Test func reservedToolsAreExcludedFromGameSources() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ToolGameSources-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let reference = try EditorProjectStore(storageURL: base.appendingPathComponent("projects.json"))
            .createProject(named: "ToolGame", at: base, template: .adaScript)
        let root = URL(fileURLWithPath: reference.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tools/Broken"), withIntermediateDirectories: true)
        try "this is intentionally invalid gameplay source @tool".write(to: root.appendingPathComponent("Tools/Broken/Broken.ada"), atomically: true, encoding: .utf8)
        var project = try ProjectSystem.loadProject(at: root)
        project.paths.sources = "."
        let artifact = try EditorAdaScriptProjectBuilder().prepare(project: project, at: root, validatesRuntime: false)
        #expect(!artifact.sources.isEmpty)
        #expect(!artifact.sources.contains { $0.path.hasPrefix("Tools/") })
    }

    @Test func projectSettingsPageOwnsEnableConsentAndRevocation() async throws {
        let fixture = try makeFixture()
        defer {
            fixture.editor.studioTools.close()
            fixture.host.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let host = fixture.editor.studioTools
        host.open(projectURL: fixture.root, editor: fixture.editor)
        let model = EditorSettingsWindowViewModel(editorViewModel: fixture.editor, selectedSection: .project, selectedPage: EditorSettingsPage.studioTools)
        #expect(model.pages(in: .project).contains(EditorSettingsPage.studioTools))
        let container = UIContainerView(rootView: EditorSettingsWindowView(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 720)
        container.layoutSubviews()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("studio.tools.enable.studio.level-helper"))
        #expect(host.permissionRequest?.presentation == .settings)
        #expect(host.panels.isEmpty)
        for _ in 0..<30 {
            await Task.yield()
            container.update(1 / 30)
            container.layoutSubviews()
        }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("studio.tools.permissions.allow"))
        #expect(host.panels.count == 1)
        for _ in 0..<30 {
            await Task.yield()
            container.update(1 / 30)
            container.layoutSubviews()
        }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("studio.tools.revoke.studio.level-helper"))
        #expect(host.panels.isEmpty)
        #expect(host.permissionRequest == nil)
    }

    @Test func legacyImplicitEnablementRequiresExplicitConsent() throws {
        let shared = try #require(UserDefaults(suiteName: "LegacyToolConsent-\(UUID())"))
        let fixture = try makeFixture(defaults: shared)
        defer {
            fixture.host.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let definition = try #require(fixture.host.definitions.first)
        let schema = definition.schema
        let legacy =
            definition.directory.path + "/" + schema.sourcePath + "|" + String(schema.apiVersion) + "|" + schema.permissions.map(\.rawValue).sorted().joined(separator: ",") + "|"
            + schema.platforms.map(\.rawValue).sorted().joined(separator: ",")
        shared.set([schema.id: legacy], forKey: "studio.tools." + fixture.root.resolvingSymlinksInPath().standardizedFileURL.path)
        fixture.host.reload()
        #expect(fixture.host.panels.isEmpty)
        fixture.host.reviewAvailableTools()
        #expect(fixture.host.permissionRequest != nil)
    }

    private func allow(_ host: EditorStudioToolHost, _ id: String) {
        host.enable(id)
        if let request = host.permissionRequest { host.approve(request.id) }
    }

    private func makeFixture(defaults: UserDefaults? = nil) throws -> (root: URL, editor: EditorViewModel, host: EditorStudioToolHost, count: Int) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudioTools-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tools"), withIntermediateDirectories: true)
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Documentation/Examples/StudioTools/LevelHelper")
        try FileManager.default.copyItem(at: example, to: root.appendingPathComponent("Tools/LevelHelper"))
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Tools", buildSystem: .adaScript), at: root)
        let model = EditorSceneModel.default(projectName: "Tools")
        let scene = root.appendingPathComponent("Assets/Main.ascn")
        try FileManager.default.createDirectory(at: scene.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = try model.encodedYAML()
        try content.write(to: scene, atomically: true, encoding: .utf8)
        let editor = EditorViewModel(project: .init(name: "Tools", path: root.path), autosaveDelay: .seconds(60))
        editor.workbench.open(
            .scene(
                .init(
                    id: "scene:Assets/Main.ascn",
                    title: "Main.ascn",
                    relativePath: "Assets/Main.ascn",
                    absolutePath: scene.path,
                    content: content,
                    lastSavedContent: content,
                    isReadOnly: false,
                    sceneModel: model,
                    errorMessage: nil,
                    isDirty: false,
                    statusMessage: nil,
                    loadSummary: EditorSceneFileLoader.summary(from: content)
                )
            )
        )
        let defaults = try #require(defaults ?? UserDefaults(suiteName: "StudioToolsTests-\(UUID())"))
        let host = EditorStudioToolHost(defaults: defaults)
        host.open(projectURL: root, editor: editor)
        return (root, editor, host, model.entities.count)
    }
}
