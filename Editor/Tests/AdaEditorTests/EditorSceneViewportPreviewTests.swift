@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite("Scene viewport UI and cameras", .serialized)
struct EditorSceneViewportPreviewTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ScenePreviewTests")))
        }
    }
    @Test("Orthographic camera frame uses scale, viewport origin and parent transform")
    func cameraFrame() throws {
        var camera = Camera()
        camera.logicalViewport = Viewport(rect: Rect(x: 0, y: 0, width: 800, height: 600))
        camera.projection = .orthographic(OrthographicProjection(viewportOrigin: Vector2(0.25, 0.75), scale: 2))
        let matrix = Transform(scale: Vector3(2, 3, 1), position: Vector3(40, 20, 10)).matrix
        let corners = try #require(EditorSceneViewportCameraGizmo.orthographicFrame(camera: camera, transform: matrix, viewport: .zero))
        #expect(corners == [Vector3(-160, -655, 10), Vector3(640, -655, 10), Vector3(640, 245, 10), Vector3(-160, 245, 10)])
    }

    @Test("Camera gizmo emits a screen-sized icon and real coverage in 2D")
    func cameraGizmoIn2D() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var context = UIGraphicsContext()
        fixture.viewport.drawGizmos(in: &context, size: fixture.size, theme: Theme())
        let lines = context.getDrawCommands().compactMap { command -> (Vector3, Vector3)? in
            if case let .drawLine(start, end, _, _) = command { return (start, end) }
            return nil
        }
        // With camera scale 2 and editor zoom 0.5, its 800x600 viewport occupies 200x150 points.
        #expect(lines.contains { abs(abs($0.1.x - $0.0.x) - 200) < 0.01 })
        #expect(lines.contains { abs(abs($0.1.y - $0.0.y) - 150) < 0.01 })
    }

    @Test("A file-backed overlay renders in the camera frame and follows scene pan and zoom")
    func overlayPreview() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EditorSceneUIPreviewHost(frame: Rect(origin: .zero, size: fixture.size))
        #expect(!host.isInteractionEnabled)
        host.viewportModel = fixture.viewport
        host.update(0)
        let first = try #require(fixture.viewport.uiPreviews(size: fixture.size).first)
        #expect(first.contentSize == Size(width: 800, height: 600))
        #expect(abs(first.transform.x.x - 0.25) < 0.001)
        #expect(abs(first.transform.origin.x - 310) < 0.001)
        #expect(abs(first.transform.origin.y + 220) < 0.001)
        let context = UIGraphicsContext()
        host.draw(with: context)
        #expect(context.getDrawCommands().contains { command in
            if case let .drawPath(_, _, .fill(color)) = command { return color == .red }
            return false
        })
        var embedded = UIGraphicsContext()
        embedded.translateBy(x: 530, y: -116)
        host.draw(with: embedded)
        let clipTransform = try #require(embedded.getDrawCommands().compactMap { command -> Transform3D? in
            if case let .pushClipPath(_, transform) = command { return transform }
            return nil
        }.first)
        #expect(abs(clipTransform.origin.x - 840) < 0.001)
        #expect(abs(clipTransform.origin.y + 336) < 0.001)
        fixture.viewport.twoDCenter = Vector2(20, 40)
        fixture.viewport.twoDZoom = 1
        host.update(0)
        let second = try #require(fixture.viewport.uiPreviews(size: fixture.size).first)
        #expect(second.view === first.view)
        #expect(abs(second.transform.x.x - 0.5) < 0.001)
        #expect(abs(second.transform.origin.x - 200) < 0.001)
        #expect(abs(second.transform.origin.y + 180) < 0.001)
        fixture.world.removeEntity(fixture.uiID)
        fixture.world.flush()
        host.update(0)
        #expect(first.view.parentView == nil)
        #expect(fixture.viewport.uiPreviews(size: fixture.size).isEmpty)
    }

    @Test("World UI uses its inherited transform and disabled parents hide previews")
    func worldPreview() throws {
        let fixture = try fixture(behaviour: "default")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preview = try #require(fixture.viewport.uiPreviews(size: fixture.size).first)
        #expect(abs(preview.transform.x.x - 0.5) < 0.001)
        // UI entity is at (100, 50), independent of the overlay camera at (20, 10).
        #expect(abs(preview.transform.origin.x - 250) < 0.001)
        #expect(abs(preview.transform.origin.y + 125) < 0.001)
        var scene = try #require(fixture.viewport.sceneModel)
        let index = try #require(scene.entities.firstIndex(where: { $0.name == "HUD" }))
        scene.entities[index].parent = "root"
        scene.updateField(typeName: EditorBuiltInComponentType.transform, field: .init(key: "position", label: "Position", kind: .vector3), value: "40, 20, 0", in: "root")
        _ = fixture.viewport.configure(sceneContent: try scene.encodedYAML(), resourceRootURL: fixture.root, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        let inherited = try #require(fixture.viewport.uiPreviews(size: fixture.size).first)
        #expect(abs(inherited.transform.origin.x - 270) < 0.001)
        #expect(abs(inherited.transform.origin.y + 115) < 0.001)
        let parent = try #require(scene.entities.firstIndex(where: { $0.id == "root" }))
        scene.entities[parent].enabled = false
        _ = fixture.viewport.configure(sceneContent: try scene.encodedYAML(), resourceRootURL: fixture.root, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        #expect(fixture.viewport.uiPreviews(size: fixture.size).isEmpty)
    }

    private struct Fixture {
        let root: URL
        let world: World
        let viewport: EditorSceneViewportModel
        let size = Size(width: 800, height: 600)
        let uiID: Entity.ID
    }

    private func fixture(behaviour: String = "overlay") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SceneUIPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ui = UISceneDocument(root: .init(type: "Rectangle", arguments: ["color": .init(value: .string("#ff0000ff"))]))
        try ui.encodedYAML().write(to: root.appendingPathComponent("HUD.ui"), atomically: true, encoding: .utf8)
        var scene = EditorSceneModel.default(projectName: "Preview")
        let cameraID = scene.addEntity(name: "Camera", parentID: nil).id
        scene.addComponent(typeName: EditorBuiltInComponentType.camera, to: cameraID)
        scene.updateField(typeName: EditorBuiltInComponentType.transform, field: .init(key: "position", label: "Position", kind: .vector3), value: "20, 10, 10", in: cameraID)
        let uiID = scene.addEntity(name: "HUD", parentID: nil).id
        scene.addComponent(typeName: EditorBuiltInComponentType.uiComponent, to: uiID)
        scene.updateField(typeName: EditorBuiltInComponentType.uiComponent, field: .init(key: "path", label: "UI", kind: .string), value: "@res://HUD.ui", in: uiID)
        scene.updateField(typeName: EditorBuiltInComponentType.uiComponent, field: .init(key: "behaviour", label: "Behaviour", kind: .string), value: behaviour, in: uiID)
        scene.updateField(typeName: EditorBuiltInComponentType.transform, field: .init(key: "position", label: "Position", kind: .vector3), value: "100, 50, 0", in: uiID)
        let content = try scene.encodedYAML()
        let world = World(name: "UIPreview")
        let result = EditorSceneFileLoader.load(content: content, into: world, loadsScriptableObjects: false, resourceRootURL: root)
        #expect(result.warnings.isEmpty)
        let cameraEntity = try #require(world.getEntities().first { $0.components[Camera.self] != nil })
        var camera = try #require(cameraEntity.components[Camera.self])
        camera.logicalViewport = Viewport(rect: Rect(x: 0, y: 0, width: 800, height: 600))
        camera.projection = .orthographic(OrthographicProjection(scale: 2))
        cameraEntity.components += camera
        cameraEntity.components += Transform(position: Vector3(20, 10, 10))
        let viewport = EditorSceneViewportModel()
        _ = viewport.configure(sceneContent: content, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        viewport.attachSceneWorld(world, loadResult: result)
        viewport.setViewportSize(Size(width: 800, height: 600))
        viewport.twoDZoom = 0.5
        viewport.twoDCenter = .zero
        return Fixture(root: root, world: world, viewport: viewport, uiID: try #require(result.entitiesByEditorID[uiID]))
    }
}
