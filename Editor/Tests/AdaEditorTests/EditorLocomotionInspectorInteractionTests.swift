@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorLocomotionInspectorUITests {
    @Test("GardenRobot clip menu uses imported names and follows scene undo and redo")
    func selectsGardenRobotClip() throws {
        EditorComponentRegistry.registerBuiltIns()
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "GardenRobotInspector")))
        }

        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let assets = repo.appendingPathComponent("Tests/AdaEngineTests/Fixtures/SkeletalGardenAssets", isDirectory: true)
        var scene = EditorSceneModel.default(projectName: "GardenRobot")
        let robot = scene.addEntity(preset: .empty)
        let index = try #require(scene.entities.firstIndex { $0.id == robot.id })
        let type = EditorBuiltInComponentType.locomotion3D
        scene.entities[index].components[EditorBuiltInComponentType.model3DSource] = [
            "source": .string("@res://GardenRobot.glb"), "animation": .string("Idle"),
            "autoplay": .bool(true), "repeats": .bool(true),
        ]
        scene.entities[index].components[String(reflecting: CharacterController3DComponent.self)] = [:]
        scene.addComponent(typeName: type, to: robot.id)
        scene.selectEntity(robot.id)
        let content = try scene.encodedYAML()
        let document = EditorSceneDocument(
            id: "scene:robot",
            title: "Main.ascn",
            relativePath: "Assets/Main.ascn",
            absolutePath: nil,
            content: content,
            sceneModel: scene,
            isDirty: false,
            loadSummary: .init(entityCount: scene.entities.count, warnings: [])
        )
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document)], activeDocumentID: document.id)
        let inspector = EditorInspectorSidebarViewModel()
        let viewport = EditorSceneViewportModel()
        defer { viewport.disconnect() }
        let update: (String, EditorComponentField, String) -> Void = { type, field, value in
            workbench.updateComponentField(typeName: type, field: field, value: value, inSelectedEntityOf: document.id)
        }
        installActions(on: inspector, owner: viewport, update: update)
        viewport.configure(
            sceneContent: content,
            model: scene,
            resourceRootURL: assets,
            onSelectionChanged: { inspector.selectEntity($0) },
            onDocumentContentChanged: { _ in },
            onLocomotionInspectorChanged: { editorID, state in
                inspector.updateLocomotionInspector(owner: viewport, editorID: editorID, state: state)
            }
        )
        #expect(inspector.selectedEntity?.locomotion?.catalog == .loading)
        let world = World()
        let loaded = EditorSceneFileLoader.load(model: scene, into: world, resourceRootURL: assets)
        #expect(loaded.warnings.isEmpty, Comment(rawValue: loaded.warnings.joined(separator: "\n")))
        viewport.attachSceneWorld(world, loadResult: loaded)

        var menu: ContextMenuPresentation?
        let previousPresenter = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { menu = $0 }
        defer { ContextMenuPresentationCenter.present = previousPresenter }
        let container = UIContainerView(rootView: EditorInspectorSidebar(viewModel: inspector).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 332, height: 820)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Inspector.Locomotion.configuration.clips.walk")
        _ = try container.uiScrollToNode(matching: selector)
        _ = try container.uiTapNode(matching: selector)
        let selectionMenu = try #require(menu)
        let clipNames = Set(selectionMenu.items.map(\.title))
        #expect(clipNames.isSuperset(of: ["Idle", "Walk", "Run", "Jump", "Fall", "Land"]))
        #expect(selectionMenu.items.filter(\.isSelected).map(\.title) == ["Walk"])
        let selectRun = try #require(selectionMenu.items.first { $0.title == "Run" }?.action)
        selectRun()

        let updated = try #require(workbench.activeSceneDocument?.content)
        #expect(updated != content)
        #expect(workbench.performDocumentHistory(redo: false))
        #expect(workbench.activeSceneDocument?.content == content)
        #expect(workbench.performDocumentHistory(redo: true))
        #expect(workbench.activeSceneDocument?.content == updated)

        #expect(workbench.performDocumentHistory(redo: false))
        let otherViewport = EditorSceneViewportModel()
        installActions(on: inspector, owner: otherViewport, update: update)
        selectRun()
        #expect(workbench.activeSceneDocument?.content == content)
        var changedState = try #require(inspector.selectedEntity?.locomotion)
        changedState.catalog = .loading
        inspector.updateLocomotionInspector(owner: viewport, editorID: robot.id, state: changedState)
        #expect(inspector.selectedEntity?.locomotion?.catalog == .ready(names: clipNames.sorted(), ambiguous: []))
    }

    @Test("Replacing GardenRobot reports a stale startup clip and uses the new model's catalog after repair")
    func replacesModel() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let assets = repo.appendingPathComponent("Tests/AdaEngineTests/Fixtures/SkeletalGardenAssets", isDirectory: true)
        EditorComponentRegistry.registerBuiltIns()
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "GardenRobotInspector")))
        }

        var scene = EditorSceneModel.default(projectName: "GardenRobot")
        let robot = scene.addEntity(preset: .empty)
        let index = try #require(scene.entities.firstIndex { $0.id == robot.id })
        let source = EditorBuiltInComponentType.model3DSource
        scene.entities[index].components[source] = ["source": .string("@res://TwoBoneRibbon.glb"), "animation": .string("Idle")]
        scene.addComponent(typeName: EditorBuiltInComponentType.locomotion3D, to: robot.id)

        func inspectorState() throws -> (state: EditorLocomotionInspectorState, playback: ModelAnimationPlayback3DComponent?) {
            let world = World()
            let result = EditorSceneFileLoader.load(model: scene, into: world, resourceRootURL: assets)
            let runtimeID = try #require(result.entitiesByEditorID[robot.id])
            let owner = try #require(world.getEntityByID(runtimeID))
            let state = EditorLocomotionInspectorState(
                entity: scene.entities[index],
                owner: owner,
                world: world,
                isLoading: false,
                sourceURL: nil,
                resourceRootURL: assets
            )
            return (state, owner.components[ModelAnimationPlayback3DComponent.self])
        }

        let brokenCatalog = try inspectorState().state.catalog
        if case let .failed(reason) = brokenCatalog {
            #expect(reason.contains("Idle"))
        } else {
            Issue.record("Expected the loader's error for the old startup clip, got \(brokenCatalog)")
        }
        scene.entities[index].components[source]?["animation"] = .string("")
        let repaired = try inspectorState().state
        #expect(repaired.catalog == .ready(names: ["Bend"], ambiguous: []))
        #expect(!repaired.hasPlaybackConflict)
        var playback = ModelAnimationPlayback3DComponent()
        playback.clip = "Bend"
        let playbackPayload = try JSONDecoder().decode(EditorComponentPayload.self, from: JSONEncoder().encode(playback))
        scene.entities[index].components[String(reflecting: ModelAnimationPlayback3DComponent.self)] = playbackPayload
        let conflict = try inspectorState()
        #expect(conflict.playback?.clip == "Bend")
        #expect(conflict.state.hasPlaybackConflict)
    }

    private func installActions(
        on inspector: EditorInspectorSidebarViewModel,
        owner: EditorSceneViewportModel,
        update: @escaping (String, EditorComponentField, String) -> Void
    ) {
        inspector.setSceneViewportActions(
            owner: owner,
            applyGizmoChange: { _ in },
            addEntity: { _ in },
            addComponent: { _ in },
            removeComponent: { _ in },
            updateComponentField: update,
            addScriptableObject: { _ in },
            removeScriptableObject: { _ in },
            updateScriptableObjectField: { _, _, _ in }
        )
    }
}
