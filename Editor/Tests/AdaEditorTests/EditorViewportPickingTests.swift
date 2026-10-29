@_spi(AdaEngine) import AdaEngine
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite
struct EditorViewportPickingTests {
    @Test("Imported mesh holes do not intercept a model behind them, including mirrored instances")
    func importedMeshHoles() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World()))
        }
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
        EditorComponentRegistry.registerBuiltIns()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Picking-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeMesh("Walls", positions: [-4, -2, 0, -2, -2, 0, -4, 2, 0, 2, -2, 0, 4, -2, 0, 4, 2, 0], in: directory)
        try writeMesh("Target", positions: [-1, -1, 0, 1, -1, 0, 0, 1, 0], in: directory)
        let model = EditorSceneModel(scene: .init(id: "picking", name: "Picking"), entities: [
            importedEntity(id: "walls", source: "Walls.gltf", z: 0),
            importedEntity(id: "target", source: "Target.gltf", z: 2),
        ])
        let world = World()
        world.spawn("SceneView_Camera") { Camera(); Transform() }
        let load = EditorSceneFileLoader.load(model: model, into: world, loadsScriptableObjects: false,
                                             sourceURL: directory.appendingPathComponent("Scene.ascn"), resourceRootURL: directory)
        #expect(load.warnings.isEmpty)
        let viewport = EditorSceneViewportModel()
        viewport.attachSceneWorld(world, loadResult: load)
        viewport.threeDPosition = [0, 0, -5]
        viewport.threeDPitch = 0
        viewport.setViewportSize(Size(width: 800, height: 600))
        viewport.setDisplayMode(.threeD)
        viewport.perspectiveBlend = 1
        viewport.setActiveTool(.select)
        var selection: String?
        viewport.onSelectEntity = { selection = $0 }
        for phase in [MouseEvent.Phase.began, .ended] {
            _ = viewport.handleInput(MouseEvent(window: RID(), button: .left, mousePosition: [400, 300], phase: phase, modifierKeys: [], time: 0))
        }
        #expect(selection == "target")
        let wallPoint = try #require(viewport.project([3.5, -1, 0], size: viewport.viewportSize))
        #expect(viewport.pick3D(at: wallPoint) == "walls")
        let walls = try #require(viewport.runtimeEntity(for: "walls"))
        walls.components[Visibility.self] = .hidden
        #expect(viewport.pick3D(at: wallPoint) == nil)
        walls.components[Visibility.self] = .visible
        walls.isActive = false
        #expect(viewport.pick3D(at: wallPoint) == nil)
    }

    @Test("Picking accepts small invertible model scales and retains world distances")
    func smallModelScale() {
        let matrix = Transform(scale: Vector3(0.001), position: [0, 0, 2]).matrix
        let bounds = BoundingComponent(bounds: .aabb(AABB(center: .zero, halfExtents: Vector3(100))))
        let ray = Ray(origin: [0, 0, -1], direction: [0, 0, 1])
        let distance = EditorPicking.intersectionDistance(ray: ray, matrix: matrix, bounds: bounds)
        #expect(abs((distance ?? 0) - 2.9) < 0.0001)
    }

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

    private func importedEntity(id: String, source: String, z: Double) -> EditorSceneEntity {
        var reference = EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.model3DSource)
        reference["source"] = .string("@res://\(source)")
        var transform = EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform)
        transform["position"] = .array([.double(0), .double(0), .double(z)])
        transform["scale"] = .array([.double(-1), .double(1), .double(1)])
        return .init(id: id, name: id, enabled: true, parent: nil, components: [
            EditorBuiltInComponentType.model3DSource: reference, EditorBuiltInComponentType.transform: transform,
        ])
    }

    private func writeMesh(_ name: String, positions: [Float], in directory: URL) throws {
        let data = positions.withUnsafeBytes { Data($0) }
        try data.write(to: directory.appendingPathComponent("\(name).bin"))
        let document: [String: Any] = [
            "asset": ["version": "2.0"], "scene": 0, "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]], "meshes": [["primitives": [["attributes": ["POSITION": 0]]]]],
            "buffers": [["uri": "\(name).bin", "byteLength": data.count]],
            "bufferViews": [["buffer": 0, "byteLength": data.count]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": positions.count / 3, "type": "VEC3"]],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: directory.appendingPathComponent("\(name).gltf"))
    }
}
