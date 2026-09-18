@_spi(AdaEngine) @testable import AdaEngine
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorFoldableTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "Foldable tests")))
        }
        EditorComponentRegistry.registerBuiltIns()
    }

    @Test func geometryAndFit() throws {
        let compact = DisplayLayout.foldable(expanded: false)
        let expanded = DisplayLayout.foldable(expanded: true)
        #expect(compact.size == Size(width: 400, height: 640))
        #expect(compact.secondary == nil && compact.hinge == nil)
        #expect(expanded.secondary == Rect(x: 420, y: 0, width: 400, height: 640))
        #expect(expanded.hinge == Rect(x: 400, y: 0, width: 20, height: 640))
        #expect(expanded.fitScale(in: Size(width: 410, height: 320)) == 0.5)
        #expect(DisplayLayout.standard(size: Size(width: 820, height: 640)).isExpanded == false)
        #expect(try JSONDecoder().decode(DisplayLayout.self, from: JSONEncoder().encode(expanded)) == expanded)
    }

    @Test func settingsRoundTripAndLegacyDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Foldable-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".ada"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var project = AdaProject(schemaVersion: 3)
        project.editor.startupScene = "Assets/Scenes/Main.ascn"
        try ProjectSystem.saveProject(project, at: root)
        let model = EditorDisplayPreviewModel()
        model.load(projectRoot: root)
        #expect(model.settings.mode == .standard)
        model.select(mode: .foldable)
        model.toggleExpanded()
        #expect(model.errorMessage == nil)
        let reopened = EditorDisplayPreviewModel()
        reopened.load(projectRoot: root)
        #expect(reopened.settings == model.settings)
        #expect(try ProjectSystem.loadProject(at: root).editor.startupScene == project.editor.startupScene)
        #expect(try JSONDecoder().decode(AdaProjectEditor.self, from: Data("{}".utf8)).displayPreview == nil)
    }

    @Test func realDemoBindingsMoveGateAndPreserveWorld() async throws {
        let root = demoRoot
        let project = try ProjectSystem.loadProject(at: root)
        let catalog = try EditorScriptableObjectCatalogLoader.load(project: project, at: root)
        let world = World(name: "Unfold demo")
        var app = AppWorlds(main: world)
        InputPlugin().setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        app.addSystem(FoldableTestTime.self)
        world.insertResource(DeltaTime(deltaTime: 0.05))
        world.insertResource(DisplayLayout.foldable(expanded: false))
        try catalog.playRuntime.install(in: &app)
        let source = try String(contentsOf: root.appendingPathComponent("Assets/Scenes/Main.ascn"), encoding: .utf8)
        let loaded = EditorSceneFileLoader.load(content: source, into: world, resourceRootURL: root.appendingPathComponent("Assets"))
        #expect(loaded.warnings.isEmpty, "\(loaded.warnings)")
        let gateID = try #require(loaded.entitiesByEditorID["gate"])
        let droneID = try #require(loaded.entitiesByEditorID["drone"])
        let gate = try #require(world.getEntities().first { $0.id == gateID })
        let panel = try #require(gate.components[CompanionPanel.self])
        for _ in 0..<80 { await world.runScheduler(.update) }
        let originalID = world.id
        let stopped = try #require(world.get(Transform.self, from: droneID)).position.y
        #expect(stopped >= -49 && stopped <= -44)
        let view = try #require(try panel.ui.resolveView(runtime: world.getResource(UIComponentRuntimeResource.self)?.runtime) as? UIContainerView<AnyView>)
        view.frame = Rect(x: 0, y: 0, width: 400, height: 640)
        view.layoutSubviews()
        world.insertResource(DisplayLayout.foldable(expanded: true))
        await world.runScheduler(.update)
        #expect(panel.ui.scriptBindingContext?.value("posture") == .string("EXPANDED / CONNECTED"))
        _ = try view.uiTapNode(matching: .accessibilityIdentifier("Unfold.Map.Gate"))
        // A UI callback queues a write, it does not mutate the scene while rendering.
        #expect(world.get(Transform.self, from: gateID)?.position.x == 0)
        for _ in 0..<80 { await world.runScheduler(.update) }
        #expect((world.get(Transform.self, from: gateID)?.position.x ?? 0) > 180)
        #expect((world.get(Transform.self, from: droneID)?.position.y ?? -220) > 100)
        for expanded in [false, true, false, true] {
            world.insertResource(DisplayLayout.foldable(expanded: expanded))
            await world.runScheduler(.update)
            #expect(panel.ui.scriptBindingContext?.value("gateOpen") == .bool(true))
            #expect(world.id == originalID)
        }
        // Enough bridge allocations to cross VM garbage-collection thresholds.
        for _ in 0..<2500 { await world.runScheduler(.update) }
        #expect(panel.ui.scriptBindingContext?.value("gateOpen") == .bool(true))
        #expect(panel.ui.scriptBindingContext?.diagnostics.isEmpty == true)
    }

    @Test func missingCompanionSourceIsReported() throws {
        var scene = EditorSceneModel.default(projectName: "Missing panel")
        let entityID = scene.addEntity(name: "Panel", parentID: nil).id
        let type = EditorBuiltInComponentType.companionPanel
        scene.addComponent(typeName: type, to: entityID)
        scene.updateField(typeName: type, field: .init(key: "path", label: "UI", kind: .string), value: "@res://Missing.ui", in: entityID)
        let result = EditorSceneFileLoader.load(content: try scene.encodedYAML(), into: World(), resourceRootURL: demoRoot.appendingPathComponent("Assets"))
        #expect(result.warnings.contains { $0.contains("Missing.ui") })
    }

    @Test func adaptiveContainerKeepsOneRuntimeAcrossLayoutChanges() async throws {
        let session = AdaptiveSceneSession()
        var creations = 0
        var updates = 0
        var worldID: World.ID?
        let make: @MainActor (inout AppWorlds) -> Void = { app in
            creations += 1
            worldID = app.main.id
            app.addPlugin(TransformPlugin())
            app.addPlugin(RenderWorldPlugin())
            app.addPlugin(CameraPlugin())
            app.addPlugin(Core2DPlugin())
        }
        let update: @MainActor (World, Float) -> Void = { world, _ in
            #expect(world.id == worldID)
            updates += 1
        }
        let surface = session.configure(layout: .foldable(expanded: false), make: make, updateContent: update)
        surface.frame = Rect(x: 0, y: 0, width: 400, height: 640)
        surface.layoutSubviews()
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(10))
            surface.update(0.016)
            surface.layoutSubviews()
        }
        #expect(creations == 1)
        #expect(updates > 0)
        for expanded in [true, false, true, false] {
            let layout = DisplayLayout.foldable(expanded: expanded)
            #expect(session.configure(layout: layout, make: make, updateContent: update) === surface)
            surface.frame = Rect(origin: .zero, size: layout.size)
            try await Task.sleep(for: .milliseconds(10))
            surface.layoutSubviews()
            let before = updates
            surface.update(0.016)
            #expect(updates == before + 1)
            #expect(creations == 1)
        }
    }

    @Test func fittedSurfaceRoutesClicksAndExcludesHinge() {
        var primaryTaps = 0
        var secondaryTaps = 0
        let content = UIContainerView(
            rootView: HStack(spacing: 0) {
                Button("Primary") { primaryTaps += 1 }.frame(width: 400, height: 640)
                Color.black.frame(width: 20, height: 640).allowsHitTesting(false)
                Button("Map") { secondaryTaps += 1 }.frame(width: 400, height: 640)
            }
        )
        let host = AdaptiveSurfaceHost()
        host.frame = Rect(x: 0, y: 0, width: 1000, height: 800)
        host.configure(previewView: content, zoom: 0.5, isInteractive: true, contentSize: Size(width: 820, height: 640))
        host.layoutSubviews()
        for x: Float in [395, 500, 610] {
            host.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: Point(x, 400), phase: .began, modifierKeys: [], time: 0))
            host.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: Point(x, 400), phase: .ended, modifierKeys: [], time: 0))
        }
        #expect(primaryTaps == 1)
        #expect(secondaryTaps == 1)
        #expect(host.previewPoint(from: Point(610, 400)) == Point(630, 320))
    }

    private var demoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Demos/UnfoldTheWorld")
    }
}

@PlainSystem(dependencies: [.before(ScriptComponentUpdateSystem.self)])
struct FoldableTestTime {
    @ResMut<DeltaTime> private var time
    init(world _: World) {}
    @MainActor func update(context _: UpdateContext) {
        time = DeltaTime(deltaTime: 0.05)
    }
}
