@_spi(AdaEngine) import AdaEngine
import Testing

@testable import AdaEditor

@Suite("Editor Gizmos")
@MainActor
struct EditorGizmoTests {
    @Test("loader preserves editor entity id mapping")
    func loaderPreservesEditorEntityIDMapping() {
        let world = World(name: "EditorGizmoLoader")
        let result = EditorSceneFileLoader.load(content: sceneYAML, into: world)

        #expect(result.entityCount == 2)
        #expect(result.entitiesByEditorID["root"] != nil)
        #expect(result.entitiesByEditorID["light"] != nil)
        if let rootRuntimeID = result.entitiesByEditorID["root"] {
            #expect(result.editorIDsByEntityID[rootRuntimeID] == "root")
        }
    }

    @Test("YAML helper adds editor gizmo without removing unknown components")
    func yamlHelperAddsEditorGizmo() throws {
        let updated = try EditorSceneYAMLDocument.upsertGizmo(
            EditorGizmo(name: "Lamp", kind: .light, isEnabled: true, size: 1.5),
            entityID: "light",
            in: sceneYAML
        )

        let decodedGizmoPayload = try EditorSceneYAMLDocument.componentPayload(named: EditorSceneYAMLDocument.editorGizmoComponentName, entityID: "light", in: updated)
        let gizmoPayload = try #require(decodedGizmoPayload)
        #expect(gizmoPayload["name"] as? String == "Lamp")
        #expect(gizmoPayload["kind"] as? String == "light")
        #expect(gizmoPayload["size"] as? Double == 1.5 || gizmoPayload["size"] as? Float == 1.5)
        #expect(try EditorSceneYAMLDocument.componentPayload(named: "Example.UnknownComponent", entityID: "light", in: updated) != nil)
    }

    @Test("YAML helper updates transform payload")
    func yamlHelperUpdatesTransform() throws {
        let updated = try EditorSceneYAMLDocument.upsertTransform(
            Transform(rotation: Quat(x: 0, y: 0, z: 0.707, w: 0.707), scale: Vector3(2, 3, 4), position: Vector3(5, 6, 7)),
            entityID: "root",
            in: sceneYAML
        )

        let decodedPayload = try EditorSceneYAMLDocument.componentPayload(named: EditorSceneYAMLDocument.transformComponentName, entityID: "root", in: updated)
        let payload = try #require(decodedPayload)
        #expect(payload["position"] as? [Double] == [5, 6, 7] || payload["position"] as? [Float] == [5, 6, 7])
        #expect(payload["scale"] as? [Double] == [2, 3, 4] || payload["scale"] as? [Float] == [2, 3, 4])
    }

    @Test("EditorGizmo decodes from scene YAML")
    func editorGizmoDecodesFromSceneYAML() {
        let world = World(name: "EditorGizmoDecode")
        let result = EditorSceneFileLoader.load(content: sceneYAMLWithGizmo, into: world)
        let entity = result.entitiesByEditorID["root"].flatMap { world.getEntityByID($0) }
        let gizmo = entity?.components[EditorGizmo.self]

        #expect(gizmo?.name == "Root Gizmo")
        #expect(gizmo?.kind == .custom)
        #expect(gizmo?.isEnabled == true)
    }

    @Test("disabled explicit gizmo is omitted from overlay model")
    func disabledGizmoIsOmittedFromOverlayModel() {
        let world = World(name: "EditorGizmoOverlayDisabled")
        let entity = world.spawn("Hidden") {
            Transform()
            EditorGizmo(name: "Hidden", kind: .custom, isEnabled: false)
        }

        let icons = EditorGizmoOverlayModel.icons(in: world, editorIDsByEntityID: [entity.id: "hidden"])
        #expect(icons.isEmpty)
    }

    @Test("light entity receives default gizmo without explicit component")
    func defaultLightGizmoIsCreated() {
        let world = World(name: "EditorGizmoOverlayLight")
        let entity = world.spawn("Point Light") {
            Transform()
            Light2D()
        }

        let icons = EditorGizmoOverlayModel.icons(in: world, editorIDsByEntityID: [entity.id: "light"])
        #expect(icons.count == 1)
        #expect(icons.first?.kind == .light)
        #expect(icons.first?.isExplicit == false)
    }
}

private let sceneYAML = """
    format: ada.scene
    schemaVersion: 1
    scene:
      id: test-scene
      name: Test
    entities:
      - id: root
        name: Root
        enabled: true
        parent:
        components:
          AdaTransform.Transform:
            position: [0, 0, 0]
            rotation: [0, 0, 0, 1]
            scale: [1, 1, 1]
      - id: light
        name: Light
        enabled: true
        parent:
        components:
          AdaTransform.Transform:
            position: [10, 20, 0]
            rotation: [0, 0, 0, 1]
            scale: [1, 1, 1]
          Example.UnknownComponent:
            value: 42
    """

private let sceneYAMLWithGizmo = """
    format: ada.scene
    schemaVersion: 1
    scene:
      id: test-scene
      name: Test
    entities:
      - id: root
        name: Root
        enabled: true
        parent:
        components:
          AdaTransform.Transform:
            position: [0, 0, 0]
            rotation: [0, 0, 0, 1]
            scale: [1, 1, 1]
          AdaScene.EditorGizmo:
            name: Root Gizmo
            kind: custom
            isEnabled: true
            size: 1
    """
