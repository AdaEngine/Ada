@_spi(Internal) @testable import AdaApp
@_spi(AdaEngine) @testable import AdaEngine
import AdaInput
@_spi(Internal) @testable import AdaRender
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Editor terrain source viewport", .serialized)
struct EditorTerrainSourceViewportTests {
    @Test("The Joining tab preserves ordinary source selection and transform handles", arguments: [false, true])
    func joiningTabKeepsSelectionAndGizmosAvailable(touch: Bool) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var model = try #require(fixture.viewport.sceneModel)
        let source = model.addEntity(template: .model3D, parentID: nil)
        let index = try #require(model.entities.firstIndex { $0.id == source.id })
        model.entities[index].components[EditorBuiltInComponentType.transform]?["position"] = .array([.double(0), .double(1), .double(0)])
        fixture.viewport.sceneModel = model
        _ = fixture.viewport.reloadSceneRuntimeIfReady()
        fixture.viewport.selectedEditorID = nil
        fixture.viewport.setActiveTool(.select)
        try await pump(fixture, frames: 8)
        let container = UIContainerView(rootView: EditorTerrainDockPanel(state: fixture.viewport.terrainEditing, onChange: {}).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1_100, height: 280)
        container.layoutSubviews()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Terrain.Tab.Joining"))
        let projected = try #require(fixture.viewport.project(Vector3(0, 1, 0), size: fixture.viewport.viewportSize))
        let point = Point(projected.x, projected.y)
        if touch {
            _ = fixture.viewport.handleTouchEvent(TouchEvent(window: .empty, location: point, phase: .began, time: 0))
            _ = fixture.viewport.handleTouchEvent(TouchEvent(window: .empty, location: point, phase: .ended, time: 0.1))
        } else {
            _ = fixture.viewport.handleMouseEvent(MouseEvent(window: .empty, button: .left, mousePosition: point, phase: .began, modifierKeys: [], time: 0))
            _ = fixture.viewport.handleMouseEvent(MouseEvent(window: .empty, button: .left, mousePosition: point, phase: .ended, modifierKeys: [], time: 0.1))
        }
        #expect(fixture.viewport.selectedEditorID == source.id)
        #expect(!fixture.viewport.terrainEditing.isSourceBusy)
        if fixture.viewport.terrainEditing.isSourceBusy {
            fixture.viewport.endTerrainStroke(cancelled: true)
            try await finish(fixture)
        }
        fixture.viewport.setActiveTool(.translate)
        #expect(fixture.viewport.transformGizmo() != nil)
    }

    @Test("Joining a selected scene mesh publishes a portable compiled terrain and one Undo record")
    func joinSelectedSceneMesh() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.viewport.terrainEditing.creationBackend = .mesh
        fixture.viewport.terrainEditing.noise.amplitude = 0
        fixture.viewport.terrainEditing.sourceActions?.create()
        try await finish(fixture)
        let terrainID = try #require(fixture.viewport.selectedEditorID)
        var model = try #require(fixture.viewport.sceneModel)
        let source = model.addEntity(template: .model3D, parentID: nil)
        let index = try #require(model.entities.firstIndex { $0.id == source.id })
        model.entities[index].components[EditorBuiltInComponentType.mesh3D]?["size"] = .double(2)
        fixture.viewport.sceneModel = model
        fixture.viewport.publishTerrainDocument()
        _ = fixture.viewport.reloadSceneRuntimeIfReady()
        fixture.viewport.selectedEditorID = source.id
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try await pump(fixture, frames: 1)
            if try await fixture.app.withWorldAccess({ fixture.viewport.runtimeEntity(for: terrainID)?.components[MeshTerrain3DSourceSurface.self] != nil }) { break }
        }
        let before = try #require(fixture.viewport.sceneModel?.entities.first { $0.id == terrainID }?.components[EditorBuiltInComponentType.terrain3DSource])
        let oldFile = try EditorTerrainResource.resolve(try EditorTerrainSourcePayload.decode(before).source, sourceURL: fixture.scene, resourceRootURL: fixture.root)
        let oldData = try Data(contentsOf: oldFile)
        let count = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0
        fixture.viewport.refreshTerrainSourceControls()
        fixture.viewport.terrainEditing.sourceActions?.join?()
        try await finish(fixture)
        let changed = try #require(fixture.viewport.sceneModel)
        let payload = changed.entities.first { $0.id == source.id }?.components[String(reflecting: MeshTerrain3DBinding.self)]
        #expect(payload != nil)
        guard let payload else { return }
        let binding = try JSONDecoder().decode(MeshTerrain3DBinding.self, from: JSONEncoder().encode(payload))
        let identity = try #require(changed.entities.first { $0.id == terrainID }?.components[String(reflecting: MeshTerrain3DIdentity.self)])
        #expect(binding.target.uuidString == identity["id"]?.stringValue)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == count + 1)
        let next = try #require(changed.entities.first { $0.id == terrainID }?.components[EditorBuiltInComponentType.terrain3DSource])
        let uri = try EditorTerrainSourcePayload.decode(next).source
        #expect(uri != (try EditorTerrainSourcePayload.decode(before).source))
        #expect(uri.hasPrefix("@res://edit-"))
        let file = try EditorTerrainResource.resolve(uri, sourceURL: fixture.scene, resourceRootURL: fixture.root)
        let manifest = try TerrainManifestAsset(data: Data(contentsOf: file))
        let name = try #require(manifest.meshDocumentFileName)
        let asset = try MeshTerrainDocumentAsset(data: Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(name)))
        #expect(try asset.acceptedCompiledProduct().patches.count == 1)
        #expect(asset.document.modifiers.first?.id == binding.modifier)
        #expect(try Data(contentsOf: oldFile) == oldData)
        try await pump(fixture, frames: 8)
        try await fixture.app.withWorldAccess {
            let root = try #require(fixture.viewport.runtimeEntity(for: source.id))
            #expect(root.components[MeshTerrain3DSourceMask.self] != nil)
            #expect(root.components[MeshTerrain3DBindingStatus.self]?.phase == .applied)
            let surface = try #require(fixture.viewport.runtimeEntity(for: terrainID)?.components[MeshTerrain3DSourceSurface.self])
            #expect(try surface.queries?.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 1)
        }
        #expect(fixture.workbench.performDocumentHistory(redo: false))
        let undone = try #require(fixture.workbench.activeSceneDocument?.sceneModel)
        #expect(undone.entities.first { $0.id == source.id }?.components[String(reflecting: MeshTerrain3DBinding.self)] == nil)
        #expect(undone.entities.first { $0.id == terrainID }?.components[EditorBuiltInComponentType.terrain3DSource] == before)
        #expect(fixture.workbench.performDocumentHistory(redo: true))
        #expect(fixture.workbench.saveActiveDocument())
        #expect(try EditorSceneModel.decode(from: String(contentsOf: fixture.scene, encoding: .utf8)).entities == changed.entities)
    }

    @Test("Create Mesh Terrain writes a compiled portable mesh document and a stable target identity")
    func createMeshTerrain() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.file)
        fixture.viewport.terrainEditing.creationBackend = .mesh
        fixture.viewport.terrainEditing.sourceActions?.create()
        try await finish(fixture)
        let model = try #require(fixture.viewport.sceneModel)
        let id = try #require(fixture.viewport.selectedEditorID)
        let entity = try #require(model.entities.first { $0.id == id })
        let payload = try #require(entity.components[EditorBuiltInComponentType.terrain3DSource])
        let source = try EditorTerrainSourcePayload.decode(payload)
        let file = try EditorTerrainResource.resolve(source.source, sourceURL: fixture.scene, resourceRootURL: fixture.root)
        let manifest = try TerrainManifestAsset(data: Data(contentsOf: file))
        #expect(manifest.meshDocumentFileName != nil)
        guard let name = manifest.meshDocumentFileName else { return }
        let document = try MeshTerrainDocumentAsset(data: Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(name)))
        #expect(try document.acceptedCompiledProduct().patches.count > 0)
        #expect(entity.components[String(reflecting: MeshTerrain3DIdentity.self)] != nil)
        #expect(manifest.heightRegions.isEmpty)
        #expect(try Data(contentsOf: fixture.file) == original)
        let decoded = try EditorSceneModel.decode(from: model.encodedYAML())
        #expect(decoded.entities.first { $0.id == id }?.components[EditorBuiltInComponentType.terrain3DSource] == payload)
    }

    @Test("The native terrain dock chooses Mesh Terrain and creates its real resource")
    func backendChoiceCreatesMeshTerrain() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.viewport.terrainEditing.creationBackend = .heightfield
        let previousPresenter = ContextMenuPresentationCenter.present
        var presentation: ContextMenuPresentation?
        ContextMenuPresentationCenter.present = { presentation = $0 }
        defer { ContextMenuPresentationCenter.present = previousPresenter }
        let container = UIContainerView(rootView: EditorTerrainDockPanel(state: fixture.viewport.terrainEditing, onChange: {}).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1_000, height: 280)
        container.layoutSubviews()
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Terrain.Backend")
        #expect(container.uiFindNodes(matching: selector).count == 1)
        guard !container.uiFindNodes(matching: selector).isEmpty else { return }
        _ = try container.uiTapNode(matching: selector)
        let menu = try #require(presentation)
        let choose = try #require(menu.items.first { $0.title == L10n.text("Mesh Terrain") }?.action)
        choose()
        #expect(fixture.viewport.terrainEditing.creationBackend == .mesh)
        container.update(1 / 60); container.layoutIfNeeded()
        presentation = nil
        _ = try container.uiTapNode(matching: selector)
        #expect(presentation?.items.filter(\.isSelected).map(\.title) == [L10n.text("Mesh Terrain")])
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Terrain.Create"))
        try await finish(fixture)
        let model = try #require(fixture.viewport.sceneModel)
        let id = try #require(fixture.viewport.selectedEditorID)
        let payload = try #require(model.entities.first { $0.id == id }?.components[EditorBuiltInComponentType.terrain3DSource])
        let source = try EditorTerrainSourcePayload.decode(payload)
        let file = try EditorTerrainResource.resolve(source.source, sourceURL: fixture.scene, resourceRootURL: fixture.root)
        #expect(try TerrainManifestAsset(data: Data(contentsOf: file)).meshDocumentFileName != nil)
    }

    @Test("Viewport source strokes publish one portable history edit; Undo, Redo and scene reopen retain heights")
    func history() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.file)
        let point = try screenPoint(fixture)
        #expect(fixture.viewport.handleTerrainPointer(at: point, began: true))
        try await pump(fixture, frames: 8)
        for _ in 0..<8 { _ = fixture.viewport.updateTerrainStroke(deltaTime: 0.05) }
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0 == 0)
        fixture.viewport.endTerrainStroke()
        try await finish(fixture)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == 1)
        let changed = try #require(fixture.workbench.activeSceneDocument?.sceneModel)
        let payload = try #require(changed.entities.first { $0.id == fixture.id }?.components[EditorBuiltInComponentType.terrain3DSource])
        let source = try EditorTerrainSourcePayload.decode(payload)
        #expect(source.source.hasPrefix("@res://edit-"))
        #expect(try Data(contentsOf: fixture.file) == original)
        let file = try EditorTerrainResource.resolve(source.source, sourceURL: fixture.scene, resourceRootURL: fixture.root)
        #expect(try await height(in: file) > 0.05)
        #expect(fixture.workbench.performDocumentHistory(redo: false))
        let undone = try #require(fixture.workbench.activeSceneDocument?.sceneModel?.entities.first { $0.id == fixture.id }?.components[EditorBuiltInComponentType.terrain3DSource])
        #expect(try EditorTerrainSourcePayload.decode(undone).source == "@res://original.aterrain")
        #expect(try await height(in: fixture.file) == 0)
        #expect(fixture.workbench.performDocumentHistory(redo: true))
        #expect(fixture.workbench.saveActiveDocument())
        let reopened = try EditorSceneModel.decode(from: String(contentsOf: fixture.scene, encoding: .utf8))
        #expect(reopened.entities == changed.entities)
    }

    @Test("Escape cancels a source gesture without a history record or private resource")
    func escape() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let point = try screenPoint(fixture)
        _ = fixture.viewport.handleTerrainPointer(at: point, began: true)
        try await pump(fixture, frames: 8)
        _ = fixture.viewport.updateTerrainStroke(deltaTime: 0.05)
        #expect(fixture.viewport.handleKeyEvent(KeyEvent(window: RID(), keyCode: .escape, modifiers: [], status: .down, time: 0, isRepeated: false)))
        fixture.viewport.endTerrainStroke()
        try await finish(fixture)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0 == 0)
        #expect(try await height(in: fixture.file) == 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(!files.contains { $0.hasPrefix("edit-") && $0.hasSuffix(".aterrain") })
    }

    @Test("Selection-only configuration during source save does not discard the completed gesture")
    func selection() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = fixture.viewport.handleTerrainPointer(at: try screenPoint(fixture), began: true)
        try await pump(fixture, frames: 8)
        for _ in 0..<8 { _ = fixture.viewport.updateTerrainStroke(deltaTime: 0.05) }
        fixture.viewport.endTerrainStroke()
        var model = try #require(fixture.viewport.sceneModel)
        model.editor?.selectedEntity = nil
        configure(fixture.viewport, model: model, root: fixture.root, scene: fixture.scene, workbench: fixture.workbench)
        try await finish(fixture)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == 1)
        #expect(fixture.viewport.sceneModel?.editor?.selectedEntity == nil)
    }

    @Test("Hidden terrain and hidden ancestors cannot receive source strokes", arguments: [false, true])
    func hidden(parentHidden: Bool) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.app.withWorldAccess {
            let owner = try #require(fixture.viewport.runtimeEntity(for: fixture.id))
            if parentHidden {
                let parent = fixture.app.main.spawn("Hidden terrain group") { Transform(); Visibility.hidden }
                parent.addChild(owner)
            } else {
                owner.components[Visibility.self] = .hidden
            }
        }
        _ = fixture.viewport.handleTerrainPointer(at: try screenPoint(fixture), began: true)
        try await pump(fixture, frames: 8)
        for _ in 0..<8 { _ = fixture.viewport.updateTerrainStroke(deltaTime: 0.05) }
        fixture.viewport.endTerrainStroke()
        try await finish(fixture)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0 == 0)
        #expect(try await height(in: fixture.file) == 0)
    }

    @Test("A nearer legacy patch remains brushable in a mixed source scene without selecting it first")
    func mixedTerrain() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var model = try #require(fixture.viewport.sceneModel)
        let id = model.addEntity(name: "Legacy patch", parentID: nil).id
        let index = try #require(model.entities.firstIndex { $0.id == id })
        var terrain = Terrain3D(resolution: 65, size: 64)
        terrain.heights = Array(repeating: 2, count: 65 * 65)
        model.entities[index].components[EditorTerrainPayload.typeName] = EditorTerrainPayload.encode(terrain)
        model.editor?.selectedEntity = nil
        configure(fixture.viewport, model: model, root: fixture.root, scene: fixture.scene, workbench: fixture.workbench)
        let point = try #require(fixture.viewport.project(Vector3(0, 2, 0), size: fixture.viewport.viewportSize))
        _ = fixture.viewport.handleTerrainPointer(at: Point(x: point.x, y: point.y), began: true)
        try await pump(fixture, frames: 8)
        for _ in 0..<8 { _ = fixture.viewport.updateTerrainStroke(deltaTime: 0.05) }
        fixture.viewport.endTerrainStroke()
        try await finish(fixture)
        let updated = try #require(fixture.viewport.sceneModel?.entities.first { $0.id == id }?.components[EditorTerrainPayload.typeName])
        #expect(EditorTerrainPayload.decode(updated)?.heights.contains(where: { $0 > 2.05 }) == true)
        let source = try #require(fixture.viewport.sceneModel?.entities.first { $0.id == fixture.id }?.components[EditorBuiltInComponentType.terrain3DSource])
        #expect(try EditorTerrainSourcePayload.decode(source).source == "@res://original.aterrain")
    }

    @Test("A changed incoming legacy document survives cancellation of its old live stroke")
    func incomingLegacyDocument() throws {
        let viewport = EditorSceneViewportModel()
        var model = EditorSceneModel.default(projectName: "Legacy")
        let id = model.addEntity(name: "Ground", parentID: nil).id
        let index = try #require(model.entities.firstIndex { $0.id == id })
        model.entities[index].components[EditorTerrainPayload.typeName] = EditorTerrainPayload.encode(Terrain3D(resolution: 17, size: 16))
        viewport.configure(sceneContent: try model.encodedYAML(), model: model, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        viewport.setViewportSize(Size(width: 800, height: 600))
        viewport.setTerrainEditing(true)
        viewport.perspectiveBlend = 1
        let point = try #require(viewport.project(.zero, size: viewport.viewportSize))
        _ = viewport.handleTerrainPointer(at: Point(x: point.x, y: point.y), began: true)
        _ = viewport.updateTerrainStroke(deltaTime: 0.05)
        var incoming = Terrain3D(resolution: 17, size: 16)
        incoming.heights = Array(repeating: 5, count: 17 * 17)
        incoming.color = Vector4(0.1, 0.3, 0.7, 1)
        model.entities[index].components[EditorTerrainPayload.typeName] = EditorTerrainPayload.encode(incoming)
        viewport.configure(sceneContent: try model.encodedYAML(), model: model, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        #expect(viewport.sceneModel?.entities[index].components[EditorTerrainPayload.typeName] == EditorTerrainPayload.encode(incoming))
    }

    @Test("A short source gesture released before asynchronous capture still applies one undoable stroke")
    func shortGesture() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let point = try screenPoint(fixture)
        _ = fixture.viewport.handleTerrainPointer(at: point, began: true)
        _ = fixture.viewport.handleTerrainPointer(at: point, ended: true)
        try await finish(fixture)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == 1)
        let payload = try #require(fixture.viewport.sceneModel?.entities.first { $0.id == fixture.id }?.components[EditorBuiltInComponentType.terrain3DSource])
        let source = try EditorTerrainSourcePayload.decode(payload)
        let file = try EditorTerrainResource.resolve(source.source, sourceURL: fixture.scene, resourceRootURL: fixture.root)
        #expect(try await height(in: file) > 0)
    }

    @Test("Source heights visibly change while the pointer is still held, before the single history commit")
    func drawingIsLive() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = fixture.viewport.handleTerrainPointer(at: try screenPoint(fixture), began: true)
        let deadline = ContinuousClock().now.advanced(by: .seconds(8))
        var changed = false
        while ContinuousClock().now < deadline {
            try await pump(fixture, frames: 1)
            _ = fixture.viewport.updateTerrainStroke(deltaTime: 0.05)
            changed = try await fixture.app.withWorldAccess {
                (fixture.viewport.runtimeEntity(for: fixture.id)?.components[Terrain3DSourceSurface.self]?.storage.height(at: .zero) ?? 0) > 0.05
            }
            if changed { break }
        }
        #expect(changed, "The running edit world must show the stroke before mouse release")
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0 == 0)
        #expect(try await height(in: fixture.file) == 0)
        fixture.viewport.endTerrainStroke()
        try await finish(fixture)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == 1)
    }

    @Test("Source hover draws a surface ring inside the viewport and invalidates cached annotations", arguments: [false, true])
    func visibleBrush(noisy: Bool) async throws {
        let fixture = try await fixture(noisy: noisy)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let presentation = EditorViewportPresentation()
        presentation.prepareFrame(viewportModel: fixture.viewport, theme: .adaEditor)()
        let previous = presentation.presentedAnnotations?.generation
        let target = try await fixture.app.withWorldAccess {
            let surface = try #require(fixture.viewport.runtimeEntity(for: fixture.id)?.components[Terrain3DSourceSurface.self])
            let height = try #require(surface.storage.height(at: Vector2(0.37, 0.41)))
            return Vector3(0.37, height, 0.41)
        }
        let projected = try #require(fixture.viewport.project(target, size: fixture.viewport.viewportSize))
        fixture.viewport.terrainEditing.radius = 0.5
        _ = fixture.viewport.handleTerrainPointer(at: Point(x: projected.x, y: projected.y))
        try await pump(fixture, frames: 8)
        var context = UIGraphicsContext()
        fixture.viewport.drawTerrainBrush(in: &context, size: fixture.viewport.viewportSize, theme: .adaEditor)
        let lines = context.getDrawCommands().compactMap { command -> (Vector3, Vector3)? in
            if case let .drawLine(start, end, _, _) = command {
                return (start, end)
            }
            return nil
        }
        #expect(lines.count == 48)
        #expect(lines.allSatisfy { $0.0.y < 0 && $0.1.y < 0 })
        presentation.prepareFrame(viewportModel: fixture.viewport, theme: .adaEditor)()
        #expect(presentation.presentedAnnotations?.generation != previous)
    }

    struct Fixture {
        let root: URL
        let file: URL
        let scene: URL
        let app: AppWorlds
        let viewport: EditorSceneViewportModel
        let workbench: EditorWorkbenchViewModel
        let id: String
    }

    @Test("Brush hover reaches a boolean solid face above the heightmap")
    func volumeBrush() async throws {
        let fixture = try await fixture(volume: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.viewport.terrainEditing.sourceTool = .paint
        fixture.viewport.terrainEditing.radius = 0.5
        let point = try #require(fixture.viewport.project(Vector3(0, 2, -4), size: fixture.viewport.viewportSize))
        _ = fixture.viewport.handleTerrainPointer(at: Point(x: point.x, y: point.y))
        try await pump(fixture, frames: 8)
        let hover = try #require(fixture.viewport.terrainEditing.hover)
        #expect(hover.point.y > 1)
        var context = UIGraphicsContext()
        fixture.viewport.drawTerrainBrush(in: &context, size: fixture.viewport.viewportSize, theme: .adaEditor)
        #expect(!context.getDrawCommands().isEmpty)
    }

    func fixture(noisy: Bool = false, volume: Bool = false) async throws -> Fixture {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TerrainViewport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("original.aterrain"), scene = root.appendingPathComponent("scene.ascn")
        var terrain = Terrain3D(resolution: 65, size: 64)
        if noisy {
            var noise = EditorTerrainNoise()
            noise.frequency = 0.35
            for z in 0..<65 {
                for x in 0..<65 {
                    terrain.heights[z * 65 + x] = noise.height(x: Float(x - 32), z: Float(z - 32))
                }
            }
        }
        let storage = try TerrainHeightStorage(importing: terrain)
        var regions: [TerrainRegionAsset] = []
        for coordinate in storage.resourceCoordinates {
            if let region = try storage.regionAsset(at: coordinate) { regions.append(region) }
        }
        let volumeSave: TerrainVolumeSave? = volume ? .init(
            document: .init(cellSize: 1, origin: [-32, 0, -32], operations: [
                .init(operation: .union, operand: .primitive(.box(halfExtents: [4, 3, 4])), transform: .init(translation: [0, 2, 0]))
            ]),
            bricks: []
        ) : nil
        _ = try await AssetsManager.saveTerrainRegions(regions, manifest: .init(spacing: 1, originX: -32, originZ: -32), at: file.path, volume: volumeSave)
        var model = EditorSceneModel.default(projectName: "Terrain")
        let id = model.addEntity(name: "Terrain", parentID: nil).id
        let index = try #require(model.entities.firstIndex { $0.id == id })
        model.entities[index].components[EditorBuiltInComponentType.terrain3DSource] = EditorTerrainSourcePayload.encode(
            Terrain3DSource(source: "@res://original.aterrain", generatesCollision: false, streamingRadius: nil, queries: .init())
        )
        let content = try model.encodedYAML()
        try content.write(to: scene, atomically: true, encoding: .utf8)
        let document = EditorSceneDocument(
            id: "terrain",
            title: "Terrain",
            relativePath: "scene.ascn",
            absolutePath: scene.path,
            content: content,
            lastSavedContent: content,
            sceneModel: model,
            errorMessage: nil,
            isDirty: false,
            statusMessage: nil,
            loadSummary: EditorSceneFileLoader.summary(from: content)
        )
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document)], activeDocumentID: "terrain")
        let app = AppWorlds(main: World(name: "Terrain viewport"))
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let viewport = EditorSceneViewportModel()
        configure(viewport, model: model, root: root, scene: scene, workbench: workbench)
        viewport.loadSceneWorld(app.main, application: app, onLoadingChanged: { _ in }, onLoaded: { _ in })
        viewport.setViewportSize(Size(width: 800, height: 600))
        viewport.setTerrainEditing(true)
        viewport.perspectiveBlend = 1
        let fixture = Fixture(root: root, file: file, scene: scene, app: app, viewport: viewport, workbench: workbench, id: id)
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while ContinuousClock().now < deadline {
            try await pump(fixture, frames: 1)
            let ready = try await app.withWorldAccess {
                viewport.entitiesByEditorID[id].flatMap { app.main.getEntityByID($0) }?.components[Terrain3DSourceStatus.self]?.isReady == true
            }
            if ready {
                return fixture
            }
        }
        throw TestFailure.notReady
    }

    private enum TestFailure: Error { case notReady }

    private func configure(_ viewport: EditorSceneViewportModel, model: EditorSceneModel, root: URL, scene: URL, workbench: EditorWorkbenchViewModel) {
        viewport.configure(
            sceneContent: (try? model.encodedYAML()) ?? "",
            model: model,
            sourceURL: scene,
            resourceRootURL: root,
            onSelectionChanged: { _ in },
            onDocumentContentChanged: { [weak viewport] content in
                workbench.updateSceneDocument(id: "terrain") { document in
                    document.content = content
                    document.sceneModel = viewport?.sceneModel
                    document.isDirty = true
                }
            }
        )
    }

    private func screenPoint(_ fixture: Fixture) throws -> Point {
        let point = try #require(fixture.viewport.project(.zero, size: fixture.viewport.viewportSize))
        return Point(x: point.x, y: point.y)
    }

    func pump(_ fixture: Fixture, frames: Int) async throws {
        for _ in 0..<frames {
            try await fixture.app.withExclusiveWorldAccess { await fixture.app.main.runScheduler(.preUpdate) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func finish(_ fixture: Fixture) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(15))
        while fixture.viewport.terrainEditing.isSourceBusy, ContinuousClock().now < deadline {
            try await pump(fixture, frames: 1)
        }
        #expect(!fixture.viewport.terrainEditing.isSourceBusy)
    }

    private func height(in file: URL) async throws -> Float {
        let cache = try await TerrainRegionCache.open(manifestAt: file.path)
        let manifest = await cache.manifest
        var regions: [TerrainRegionAsset] = []
        for reference in manifest.heightRegions {
            if let region = try await cache.loadRegion(at: .init(x: Int(reference.x), z: Int(reference.z))) { regions.append(region) }
        }
        let storage = try TerrainHeightStorage(regions: regions, spacing: manifest.spacing, origin: [manifest.originX, manifest.originZ])
        return try #require(storage.height(at: .zero))
    }
}
