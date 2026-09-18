@_spi(AdaEngine) @testable import AdaEngine
import AdaInput
@_spi(Internal) import AdaRender
@_spi(Internal) @testable import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorMeshInspectorTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "MeshInspectorTests")))
        }
        EditorComponentRegistry.registerBuiltIns()
    }

    @Test("Checkmark renders as a stroke without depending on a font glyph")
    func checkmarkDrawing() throws {
        let container = UIContainerView(rootView: ContextMenuCheckmark().stroke(Color.white, lineWidth: 1.8).frame(width: 12, height: 12))
        container.frame = Rect(x: 0, y: 0, width: 12, height: 12)
        container.layoutIfNeeded()
        let context = UIGraphicsContext()
        container.viewTree.rootNode.draw(with: context)
        let strokes = context.getDrawCommands()
            .compactMap { command -> Path? in
                guard case let .drawPath(path, _, .stroke) = command else {
                    return nil
                }
                return path
            }
        #expect(strokes.count == 1)
        var lines = 0
        strokes.first?
            .forEach {
                if case .line = $0 {
                    lines += 1
                }
            }
        #expect(lines == 2)
        #expect(ContextMenuMetrics.titleWidth(menuWidth: 184, hasSubmenu: false, hasSelection: true) == 144)
    }

    @Test("Each built-in primitive has renderable buffers, UVs, and outward normals", arguments: EditorMeshPrimitive.allCases)
    func primitiveGeometry(primitive: EditorMeshPrimitive) throws {
        let mesh = primitive.makeMesh(renderDevice: unsafe RenderEngine.shared.renderDevice)
        let part = try #require(mesh.models.first?.parts.first)
        let positions = part.meshDescriptor.positions.elements
        let normals = try #require(part.meshDescriptor.normals?.elements)
        let uvs = try #require(part.meshDescriptor.textureCoordinates?.elements)
        #expect(positions.count == normals.count && positions.count == uvs.count)
        #expect(part.indexCount > 0 && part.indexCount.isMultiple(of: 3))
        for index in stride(from: 0, to: part.indexCount, by: 3) {
            let triangle = part.meshDescriptor.indicies[index..<(index + 3)].map(Int.init)
            #expect(triangle.allSatisfy { positions.indices.contains($0) })
            let a = positions[triangle[1]] - positions[triangle[0]]
            let b = positions[triangle[2]] - positions[triangle[0]]
            let cross = Vector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
            let normal = normals[triangle[0]]
            #expect(cross.x * normal.x + cross.y * normal.y + cross.z * normal.z >= -0.00001)
        }
    }

    @Test("Mesh selection survives a scene file and loads real mesh components", arguments: [false, true])
    func selectionPersists(is3D: Bool) throws {
        let type = is3D ? EditorBuiltInComponentType.mesh3D : EditorBuiltInComponentType.mesh2D
        let descriptor = try #require(EditorComponentRegistry.descriptor(named: type))
        let field = try #require(descriptor.fields.first { $0.key == "mesh" })
        guard case let .enumeration(choices) = field.kind else {
            Issue.record("Missing mesh picker")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-\(UUID().uuidString).ascn")
        defer { try? FileManager.default.removeItem(at: url) }
        for choice in choices {
            var scene = EditorSceneModel.default(projectName: "Mesh")
            let entity = scene.addEntity(preset: .empty)
            scene.addComponent(typeName: type, to: entity.id)
            scene.updateField(typeName: type, field: field, value: choice, in: entity.id)
            try scene.encodedYAML().write(to: url, atomically: true, encoding: .utf8)
            let restored = try String(contentsOf: url, encoding: .utf8)
            let world = World()
            let result = EditorSceneFileLoader.load(content: restored, into: world, loadsScriptableObjects: false)
            #expect(result.warnings.isEmpty, Comment(rawValue: result.warnings.joined(separator: "\n")))
            let id = try #require(result.entitiesByEditorID[entity.id])
            let live = try #require(world.getEntityByID(id))
            let mesh: Mesh
            if is3D {
                let component = try #require(live.components[Mesh3DComponent.self])
                mesh = component.mesh
                #expect(component.materials.first is PBRMaterial)
            } else {
                let component = try #require(live.components[Mesh2D.self])
                mesh = component.mesh
                let material = try #require(component.materials.first as? CustomMaterial<ColorCanvasMaterial>)
                #expect(material.shaderSource.getSource(for: .vertex) != nil)
                #expect(material.shaderSource.getSource(for: .fragment) != nil)
            }
            #expect(mesh.models.first?.parts.first?.meshDescriptor.name == choice)
            #expect(try EditorSceneModel.decode(from: restored).entities.first { $0.id == entity.id }?.components[type]?["mesh"] == .string(choice))
        }
    }

    @Test("Inspector picker selects sphere, then cube, and marks the current choice")
    func liveMeshPicker() async throws {
        var scene = EditorSceneModel.default(projectName: "Mesh UI")
        let entity = scene.addEntity(preset: .empty)
        scene.addComponent(typeName: EditorBuiltInComponentType.mesh2D, to: entity.id)
        let viewport = EditorSceneViewportModel()
        defer { viewport.disconnect() }
        let inspector = EditorInspectorSidebarViewModel()
        viewport.configure(sceneContent: try scene.encodedYAML(), onSelectionChanged: { inspector.selectEntity($0) }, onDocumentContentChanged: { _ in })
        inspector.updateComponentField = { type, field, value in
            scene.updateField(typeName: type, field: field, value: value, in: entity.id)
            do {
                viewport.configure(
                    sceneContent: try scene.encodedYAML(),
                    onSelectionChanged: { inspector.selectEntity($0) },
                    onDocumentContentChanged: { _ in }
                )
            } catch {
                Issue.record(error)
            }
        }
        let container = UIContainerView(rootView: EditorInspectorSidebar(viewModel: inspector))
        container.frame = Rect(x: 0, y: 0, width: 380, height: 900)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        var menu: ContextMenuPresentation?
        let previous = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { menu = $0 }
        defer { ContextMenuPresentationCenter.present = previous }
        var selected = "Quad"
        for choice in ["Sphere", "Cube"] {
            let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Inspector.Enum.\(EditorBuiltInComponentType.mesh2D).mesh")
            _ = try container.uiScrollToNode(matching: selector)
            _ = try container.uiTapNode(matching: selector)
            #expect(menu?.items.filter(\.isSelected).map(\.title) == [selected])
            let action = try #require(menu?.items.first { $0.title == choice }?.action)
            action()
            selected = choice
            for _ in 0..<10 {
                await Task.yield()
                container.update(1.0 / 60.0)
                container.layoutIfNeeded()
            }
            let payload = try #require(scene.entities.first { $0.id == entity.id }?.components[EditorBuiltInComponentType.mesh2D])
            let live = try #require(EditorComponentRegistry.decode(typeName: EditorBuiltInComponentType.mesh2D, payload: payload) as? Mesh2D)
            #expect(live.mesh.models.first?.parts.first?.meshDescriptor.name == choice)
        }
    }
}
