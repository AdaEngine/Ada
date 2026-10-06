@_spi(AdaEngine) import AdaEngine
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite
struct EditorViewportPickingTests {
    @Test("Picking follows the displayed orthographic, transition and perspective camera", arguments: [Float(0), 0.25, 0.5, 0.75, 1])
    func pickingFollowsProjection(blend: Float) throws {
        let point = Vector3(0.2, 0.1, 0)
        let pose = Transform(position: point)
        let scene = EditorSceneModel.default(projectName: "Picking")
        let editorID = try #require(scene.rootEntityID)
        let world = World()
        world.spawn("SceneView_Camera") { Camera(); Transform() }
        let target = world.spawn("Target") { pose }
        let viewport = EditorSceneViewportModel()
        viewport.attachSceneWorld(world, loadResult: .init(
            entityCount: 1, warnings: [], entitiesByEditorID: [editorID: target.id], editorIDsByEntityID: [target.id: editorID]
        ))
        viewport.setViewportSize(Size(width: 1_280, height: 720))
        viewport.setDisplayMode(.threeD)
        viewport.perspectiveBlend = blend
        let projected = try #require(viewport.project(point, size: viewport.viewportSize))
        #expect(viewport.pick3D(at: projected) == editorID)
        #expect(target.components[GlobalTransform.self]?.matrix == .identity, "Picking must work before the transform scheduler runs")
    }

    @Test("Picking sees local edits and composed parent transforms before propagation")
    func parentAndLocalEdits() throws {
        let world = World()
        world.spawn("SceneView_Camera") { Camera(); Transform() }
        let parent = world.spawn("Parent") { Transform(rotation: Quat(axis: .up, angle: .pi / 3), scale: Vector3(2), position: [3, 0, 1]) }
        let target = world.spawn("Target") { Transform(position: [0.5, 0, 0]) }
        parent.addChild(target)
        let viewport = EditorSceneViewportModel()
        viewport.attachSceneWorld(world, loadResult: .init(
            entityCount: 1, warnings: [], entitiesByEditorID: ["target": target.id], editorIDsByEntityID: [target.id: "target"]
        ))
        viewport.setViewportSize(Size(width: 1_280, height: 720))
        viewport.setDisplayMode(.threeD)
        viewport.perspectiveBlend = 1
        for position: Vector3 in [[0.5, 0, 0], [-0.5, 0.4, 0.5]] {
            target.components[Transform.self] = Transform(position: position)
            let parentMatrix = try #require(parent.components[Transform.self]?.matrix)
            let center = (parentMatrix * Vector4(position, 1)).xyz
            let projected = try #require(viewport.project(center, size: viewport.viewportSize))
            #expect(viewport.pick3D(at: projected) == "target")
        }
    }

    @Test("Unprojection accepts small valid orthographic determinants and rejects invalid geometry")
    func rayValidity() throws {
        let viewport = EditorSceneViewportModel()
        viewport.twoDZoom = 1
        let size = Size(width: 1_280, height: 720)
        let state = viewport.cameraState(for: size)
        let ray = try #require(EditorPicking.ray(
            point: Point(640, 360),
            viewportSize: size,
            cameraTransform: state.transform.matrix,
            projection: state.projection.makeClipView()
        ))
        #expect(abs(ray.direction.z - 1) < 0.00001)
        #expect(EditorPicking.ray(point: .zero, viewportSize: .zero, cameraTransform: .identity, projection: .identity) == nil)
    }
}
