@_spi(AdaEngine) import AdaEngine
import Testing

@testable import AdaEditor

@MainActor
@Suite
struct EditorLiveSceneEditsTests {
    @Test
    func hierarchyAndInspectorEditsRetainTheViewport() async throws {
        EditorComponentRegistry.registerBuiltIns()
        let world = World()
        let application = AppWorlds(main: world)
        let viewport = EditorSceneViewportModel()
        defer { viewport.disconnect() }
        let transform = EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform)
        let entities = (0..<132).map { index in
            EditorSceneEntity(
                id: "item-\(index)",
                name: "Item \(index)",
                enabled: true,
                parent: nil,
                components: [EditorBuiltInComponentType.transform: transform]
            )
        }
        let initial = EditorSceneModel(scene: .init(id: "live-scene", name: "Live scene"), entities: entities)
        func configure(_ model: EditorSceneModel, revision: Int, history: Bool = false) {
            viewport.configure(
                sceneContent: "revision-\(revision)",
                model: model,
                isHistoryChange: history,
                onSelectionChanged: { _ in },
                onDocumentContentChanged: { _ in }
            )
        }
        configure(initial, revision: 0)
        var loading: [Bool] = []
        var published = 0
        viewport.loadSceneWorld(
            world,
            application: application,
            onLoadingChanged: { loading.append($0) },
            onLoaded: { _ in published += 1 }
        )
        func waitForPublication(_ count: Int) async throws {
            for _ in 0..<500 where published < count { try await Task.sleep(for: .milliseconds(4)) }
            try #require(published >= count)
        }
        try await waitForPublication(1)
        let unaffected = try #require(viewport.runtimeEntity(for: "item-0"))
        let original = try #require(viewport.runtimeEntity(for: "item-1"))
        loading.removeAll()

        var edited = initial
        edited.entities[1].enabled = false
        edited.entities[1].parent = "item-2"
        edited.entities[1].components[EditorBuiltInComponentType.transform]?["position"] = .array([.int(2), .int(3), .int(4)])
        edited.entities.remove(at: 3)
        edited.entities.append(.init(id: "new", name: "New", enabled: true, parent: "item-2", components: [:]))
        configure(edited, revision: 1)
        try await waitForPublication(2)
        #expect(loading.isEmpty, "Live edits must never start the scene-loading path")
        #expect(viewport.runtimeEntity(for: "item-0") === unaffected)
        #expect(viewport.runtimeEntity(for: "item-1") === original)
        let editedItem = try #require(viewport.runtimeEntity(for: "item-1"))
        #expect(!editedItem.isActive)
        #expect(editedItem.parent === viewport.runtimeEntity(for: "item-2"))
        #expect(editedItem.components[Transform.self]?.position == Vector3(2, 3, 4))
        #expect(viewport.runtimeEntity(for: "item-3") == nil)
        #expect(viewport.runtimeEntity(for: "new")?.parent === editedItem.parent)

        configure(initial, revision: 2, history: true)
        try await waitForPublication(3)
        #expect(loading.isEmpty)
        #expect(viewport.runtimeEntity(for: "item-0") === unaffected)
        #expect(viewport.runtimeEntity(for: "item-1") === original)
        #expect(viewport.runtimeEntity(for: "item-1")?.isActive == true)
        #expect(viewport.runtimeEntity(for: "item-1")?.parent == nil)
        #expect(viewport.runtimeEntity(for: "item-3") != nil)
        #expect(viewport.runtimeEntity(for: "new") == nil)

        configure(edited, revision: 3, history: true)
        try await waitForPublication(4)
        #expect(loading.isEmpty)
        #expect(viewport.runtimeEntity(for: "item-0") === unaffected)
        #expect(viewport.runtimeEntity(for: "item-1")?.parent === viewport.runtimeEntity(for: "item-2"))
        #expect(viewport.runtimeEntity(for: "new") != nil)
    }
}
