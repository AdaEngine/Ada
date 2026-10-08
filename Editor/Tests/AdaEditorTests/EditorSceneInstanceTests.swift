@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor scene instances")
struct EditorSceneInstanceTests {
    @Test("scene instance is an addable component with a scene-reference field")
    func sceneInstanceDescriptor() throws {
        let descriptor = try #require(EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.sceneInstance))
        #expect(descriptor.displayName == "Scene Instance")
        #expect(descriptor.requiredComponentTypeNames.contains(EditorBuiltInComponentType.transform))
        #expect(descriptor.fields == [EditorComponentField(key: "scene", label: "Scene", kind: .sceneReference)])

        var payload = descriptor.makeDefaultPayload()
        descriptor.fields[0].write("@res://Prefabs/Enemy.ascn", to: &payload)
        #expect(payload["scene"] == .string("@res://Prefabs/Enemy.ascn"))
    }

    @Test("inspector scene catalog assigns a project scene reference")
    @MainActor
    func inspectorScenePickerAssignsReference() throws {
        let descriptor = try #require(EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.sceneInstance))
        let field = try #require(descriptor.fields.first)
        let viewModel = EditorInspectorSidebarViewModel()
        viewModel.sceneAssets = [
            .init(
                name: "Enemy.ascn",
                reference: "@res://Prefabs/Enemy.ascn",
                absolutePath: "/tmp/Game/Assets/Prefabs/Enemy.ascn"
            )
        ]
        var appliedValue: String?
        viewModel.updateComponentField = { _, _, value in appliedValue = value }
        viewModel.selectEntity(
            EditorInspectorSidebarViewModel.SelectedEntity(
                editorID: "instance",
                name: "Enemy Instance",
                componentNames: [EditorBuiltInComponentType.sceneInstance],
                transformFields: [],
                components: [
                    .init(
                        typeName: EditorBuiltInComponentType.sceneInstance,
                        displayName: descriptor.displayName,
                        fields: [.init(typeName: EditorBuiltInComponentType.sceneInstance, field: field, value: "")],
                        canRemove: true
                    )
                ],
                addableComponents: [],
                gizmo: nil,
                hasExplicitGizmo: false
            )
        )

        #expect(viewModel.sceneAssets(matching: "enemy").map(\.reference) == ["@res://Prefabs/Enemy.ascn"])
        viewModel.componentFieldBinding(typeName: EditorBuiltInComponentType.sceneInstance, field: field).wrappedValue = "@res://Prefabs/Enemy.ascn"

        #expect(appliedValue == "@res://Prefabs/Enemy.ascn")
    }

    @Test("the same scene prefab creates independent child hierarchies")
    @MainActor
    func repeatedPrefabInstancesCreateIndependentHierarchies() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let prefab = EditorSceneModel.default(projectName: "Enemy")
        try prefab.encodedYAML().write(to: fixture.prefabURL, atomically: true, encoding: .utf8)
        let main = makeMainScene(instanceIDs: ["enemy-a", "enemy-b"], reference: "@res://Prefabs/Enemy.ascn")
        let content = try main.encodedYAML()
        try content.write(to: fixture.mainURL, atomically: true, encoding: .utf8)

        let world = World()
        let result = EditorSceneFileLoader.load(
            content: content,
            into: world,
            sourceURL: fixture.mainURL,
            resourceRootURL: fixture.assetsURL
        )

        #expect(result.warnings.isEmpty)
        #expect(result.entityCount == 4)
        let firstID = try #require(result.entitiesByEditorID["enemy-a"])
        let secondID = try #require(result.entitiesByEditorID["enemy-b"])
        let first = try #require(world.getEntityByID(firstID))
        let second = try #require(world.getEntityByID(secondID))
        let firstPrefabRoot = try #require(first.children.first)
        let secondPrefabRoot = try #require(second.children.first)
        #expect(firstPrefabRoot.id != secondPrefabRoot.id)
        #expect(firstPrefabRoot.parent === first)
        #expect(secondPrefabRoot.parent === second)
        #expect(result.editorIDsByEntityID[firstPrefabRoot.id] == "enemy-a")
        #expect(result.editorIDsByEntityID[secondPrefabRoot.id] == "enemy-b")
    }

    @Test("nested scene cycles stop at the instance boundary")
    @MainActor
    func nestedSceneCyclesAreRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let main = makeMainScene(instanceIDs: ["prefab"], reference: "@res://Prefabs/Enemy.ascn")
        let mainContent = try main.encodedYAML()
        try mainContent.write(to: fixture.mainURL, atomically: true, encoding: .utf8)
        let recursivePrefab = makeMainScene(instanceIDs: ["recursive"], reference: "@res://Main.ascn")
        try recursivePrefab.encodedYAML().write(to: fixture.prefabURL, atomically: true, encoding: .utf8)

        let result = EditorSceneFileLoader.load(
            content: mainContent,
            into: World(),
            sourceURL: fixture.mainURL,
            resourceRootURL: fixture.assetsURL
        )

        #expect(result.entityCount == 2)
        #expect(result.warnings.contains { $0.contains("Nested scene cycle") })
    }

    private func makeMainScene(instanceIDs: [String], reference: String) -> EditorSceneModel {
        EditorSceneModel(
            scene: EditorSceneMetadata(id: UUID().uuidString, name: "Main"),
            entities: instanceIDs.map { id in
                EditorSceneEntity(
                    id: id,
                    name: id,
                    enabled: true,
                    parent: nil,
                    components: [
                        EditorBuiltInComponentType.transform: EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform),
                        EditorBuiltInComponentType.sceneInstance: ["scene": .string(reference)],
                    ]
                )
            }
        )
    }

    private func makeFixture() throws -> (rootURL: URL, assetsURL: URL, mainURL: URL, prefabURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaEditorSceneInstanceTests-\(UUID().uuidString)", isDirectory: true)
        let assetsURL = rootURL.appendingPathComponent("Assets", isDirectory: true)
        let prefabsURL = assetsURL.appendingPathComponent("Prefabs", isDirectory: true)
        try FileManager.default.createDirectory(at: prefabsURL, withIntermediateDirectories: true)
        return (
            rootURL,
            assetsURL,
            assetsURL.appendingPathComponent("Main.ascn", isDirectory: false),
            prefabsURL.appendingPathComponent("Enemy.ascn", isDirectory: false)
        )
    }
}
