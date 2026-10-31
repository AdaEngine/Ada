@testable import AdaApp
@testable import AdaCorePipelines
@_spi(AdaEngine) @testable import AdaEngine
import AdaInput
@_spi(Internal) @testable import AdaRender
@_spi(Internal) @testable import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite("Scene performance regressions", .serialized)
struct EditorScenePerformanceRegressionTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ScenePerformanceTests")))
        }
    }

    @Test("3D camera uniforms reuse in-flight buffers while uploading current matrices")
    func viewUniformBuffersStayReusable() async throws {
        let device = try #require(unsafe RenderEngine.shared).renderDevice
        let frames = max(1, unsafe RenderEngine.configurations.maxFramesInFlight)
        var scratch = View3DGPUScratch()
        var buffers: [any Buffer] = []
        for frame in 0..<(frames * 3) {
            let matrix = Transform3D(translation: [Float(frame), 2, 3])
            let value = GlobalViewUniform(viewMatrix: matrix)
            let constants = scratch.cache.write(value, view: 1, device: device)
            let buffer = try #require(constants.buffer)
            buffers.append(buffer)
            let bytes = try await buffer.readData()
            #expect(bytes.count >= MemoryLayout<GlobalViewUniform>.stride)
            let uploaded = bytes.withUnsafeBytes { unsafe $0.loadUnaligned(as: GlobalViewUniform.self) }
            #expect(uploaded.viewMatrix == matrix)
        }
        let identities = Set(buffers.map(ObjectIdentifier.init))
        #expect(identities.count == frames)
        let other = scratch.cache.write(GlobalViewUniform(), view: 2, device: device)
        #expect(!identities.contains(ObjectIdentifier(try #require(other.buffer))))
        scratch.cache.retainViews([2])
        let recreated = scratch.cache.write(GlobalViewUniform(), view: 1, device: device)
        #expect(!identities.contains(ObjectIdentifier(try #require(recreated.buffer))))
    }

    @Test("Equal material parameters share immutable buffers while edits preserve in-flight data")
    func materialUniformsShareValues() async throws {
        let device = try #require(unsafe RenderEngine.shared).renderDevice
        var uniforms = PBR3DUniforms()
        uniforms.beginFrame()
        let first = PBRMaterial()
        let second = PBRMaterial()
        first.baseColorFactor = [1, 0, 0, 1]
        second.baseColorFactor = [0, 0, 1, 1]
        first.roughnessFactor = 0.2
        second.roughnessFactor = 0.8
        let descriptor = VertexDescriptor()
        uniforms.write(material: first, descriptor: descriptor, device: device)
        uniforms.write(material: second, descriptor: descriptor, device: device)
        let original = try #require(uniforms.buffer(for: first))
        #expect(uniforms.buffer(for: second) === original)
        let originalBytes = try await original.readData()
        first.normalScale = 2
        first.baseColorFactor.w = 0.5
        first.doubleSided = true
        first.textureCoordinates[0] = 1
        uniforms.write(material: first, descriptor: descriptor, device: device)
        let edited = try #require(uniforms.buffer(for: first))
        #expect(edited !== original)
        #expect(uniforms.buffer(for: second) === original)
        #expect(try await original.readData() == originalBytes)
        let bytes = try await edited.readData()
        let uploaded = bytes.withUnsafeBytes { unsafe $0.loadUnaligned(as: PBR3DUniform.self) }
        #expect(uploaded.properties.x == 2)
        #expect(uploaded.emission.y == 0.5)
        #expect(uploaded.flags.x == 1)
        #expect(uploaded.coordinates.x == 1)
    }

    @Test("Shared material buffers survive frame changes and unused values are pruned")
    func materialUniformsPruneUnusedValues() throws {
        let device = try #require(unsafe RenderEngine.shared).renderDevice
        var uniforms = PBR3DUniforms()
        let first = PBRMaterial()
        let second = PBRMaterial()
        let descriptor = VertexDescriptor()
        uniforms.beginFrame()
        uniforms.write(material: first, descriptor: descriptor, device: device)
        let shared = try #require(uniforms.buffer(for: first))
        first.normalScale = 2
        uniforms.write(material: first, descriptor: descriptor, device: device)
        let retired = try #require(uniforms.buffer(for: first))
        for _ in 0..<12 {
            uniforms.beginFrame()
            #expect(uniforms.buffer(for: first) == nil)
            uniforms.write(material: second, descriptor: descriptor, device: device)
            #expect(uniforms.buffer(for: second) === shared)
        }
        uniforms.write(material: first, descriptor: descriptor, device: device)
        #expect(uniforms.buffer(for: first) !== retired)
    }

    @Test("Material cache keys preserve NaN payloads and signed zero")
    func materialUniformBitsRemainDistinct() async throws {
        let device = try #require(unsafe RenderEngine.shared).renderDevice
        var uniforms = PBR3DUniforms()
        let first = PBRMaterial()
        let second = PBRMaterial()
        let descriptor = VertexDescriptor()
        first.normalScale = Float(bitPattern: 0x7FC01234)
        second.normalScale = first.normalScale
        uniforms.write(material: first, descriptor: descriptor, device: device)
        uniforms.write(material: second, descriptor: descriptor, device: device)
        let nanBuffer = try #require(uniforms.buffer(for: first))
        #expect(nanBuffer === uniforms.buffer(for: second))
        first.normalScale = 0
        second.normalScale = -0.0
        uniforms.write(material: first, descriptor: descriptor, device: device)
        uniforms.write(material: second, descriptor: descriptor, device: device)
        let negative = try #require(uniforms.buffer(for: second))
        #expect(uniforms.buffer(for: first) !== negative)
        let bytes = try await negative.readData()
        let uploaded = bytes.withUnsafeBytes { unsafe $0.loadUnaligned(as: PBR3DUniform.self) }
        #expect(uploaded.properties.x.bitPattern == 0x80000000)
    }

    @Test("UI projections reuse buffers independently for each camera")
    func uiUniformBuffersStayReusable() async throws {
        let device = try #require(unsafe RenderEngine.shared).renderDevice
        let frames = max(1, unsafe RenderEngine.configurations.maxFramesInFlight)
        var uniforms = UIViewUniform()
        var retained: [any Buffer] = []
        for frame in 0..<(frames * 3) {
            let projection = Transform3D.createUIProjection(width: Float(640 + frame), height: 400)
            let constants = uniforms.write(GlobalViewUniform(projectionMatrix: projection), view: 1, device: device)
            let buffer = try #require(constants.buffer)
            retained.append(buffer)
            let bytes = try await buffer.readData()
            let uploaded = bytes.withUnsafeBytes { unsafe $0.loadUnaligned(as: GlobalViewUniform.self) }
            #expect(uploaded.projectionMatrix == projection)
        }
        let identities = Set(retained.map(ObjectIdentifier.init))
        #expect(identities.count == frames)
        let other = uniforms.write(GlobalViewUniform(), view: 2, device: device)
        #expect(!identities.contains(ObjectIdentifier(try #require(other.buffer))))
        uniforms.retainViews([2])
        let recreated = uniforms.write(GlobalViewUniform(), view: 1, device: device)
        #expect(!identities.contains(ObjectIdentifier(try #require(recreated.buffer))))
    }

    @Test("Inactive preview skips host frames while remaining available for tooling and explicit updates")
    func inactivePreviewRetainsWorld() async throws {
        let previousHost = AppWorldsSession.current
        let host = AppWorlds(main: World(name: "PreviewHost"))
        MainSchedulerPlugin().setup(in: host)
        try await host.build()
        AppWorldsSession.current = host
        defer { AppWorldsSession.current = previousHost }
        var updates = 0
        let coordinator = SceneViewCoordinator(make: { $0.addPlugin(PreviewFrameProbePlugin()) }, updateContent: { _, _ in updates += 1 })
        defer { coordinator.shutdown() }
        coordinator.setRenderingEnabled(false)
        coordinator.bootstrapIfNeeded()
        for _ in 0..<500 where coordinator.appWorlds == nil { await Task.yield() }
        let app = try #require(coordinator.appWorlds)
        coordinator.updateSize(SizeInt(width: 32, height: 32), scaleFactor: 1)
        let name = try #require(host.allWorldNames().first { $0 != .main })
        #expect(host.getSubworldBuilder(by: name) === app)
        let renderProbe = try #require(app.getSubworldBuilder(by: .init(rawValue: "PreviewRenderProbe")))
        coordinator.tick(0.016)
        try await host.update()
        #expect(updates == 0)
        #expect(app.main.getResource(PreviewFrameCount.self)?.count == 0)
        #expect(renderProbe.main.getResource(PreviewFrameCount.self)?.count == 0)
        try await app.update()
        #expect(app.main.getResource(PreviewFrameCount.self)?.count == 1)
        #expect(renderProbe.main.getResource(PreviewFrameCount.self)?.count == 1)
        coordinator.setRenderingEnabled(true)
        #expect(host.getSubworldBuilder(by: name) === app)
        coordinator.tick(0.016)
        try await host.update()
        #expect(updates == 1)
        #expect(app.main.getResource(PreviewFrameCount.self)?.count == 2)
        #expect(renderProbe.main.getResource(PreviewFrameCount.self)?.count == 2)
        coordinator.setRenderingEnabled(false)
        #expect(host.getSubworldBuilder(by: name) === app)
        coordinator.tick(0.016)
        try await host.update()
        #expect(updates == 1)
        #expect(app.main.getResource(PreviewFrameCount.self)?.count == 2)
        #expect(renderProbe.main.getResource(PreviewFrameCount.self)?.count == 2)
        coordinator.setRenderingEnabled(true)
        #expect(host.getSubworldBuilder(by: name) === app)
        coordinator.shutdown()
        #expect(host.getSubworldBuilder(by: name) == nil)
    }

    @Test("A large asset tree mounts visible rows and opens a distant file after scrolling")
    func projectTreeUsesVisibleRows() throws {
        let items = (0..<600).map { index in
            EditorProjectSidebarViewModel.Item(
                id: "Scene\(index).ascn", disclosure: "", icon: "", title: "Scene\(index).ascn",
                relativePath: "Scene\(index).ascn", level: 0, isActive: false, isFolder: false, kind: .scene
            )
        }
        let model = EditorProjectSidebarViewModel(items: items, displayMode: .files)
        let selection = HierarchySelection()
        let container = UIContainerView(rootView: EditorProjectSidebar(
            viewModel: model, projectRootItem: nil, onOpenItem: { selection.id = $0.id },
            onOpenRawItem: { _ in }, onNewFile: { _ in }, onImportAssets: {}, onDropFiles: { _ in true },
            onRevealItem: { _ in }, onOpenInDefaultApplication: { _ in }, onOpenInTerminal: { _ in },
            onFindInFolder: { _ in }, onFindInProjectRoot: {}, onCopyPath: { _, _ in }, onDeleteItem: { _ in }
        ))
        container.frame = Rect(x: 0, y: 0, width: 320, height: 400)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let root = container.viewTree.rootNode
        let mounted = root.uiCollectNodes { $0.accessibilityIdentifier?.hasPrefix("AdaEditor.ProjectTree.Scene") == true }
        #expect(!mounted.isEmpty && mounted.count < 60)
        let last = try #require(items.last)
        let scroll = try #require(root.uiCollectNodes { $0 is ScrollViewNode }.first as? ScrollViewNode)
        scroll.scrollToViewNodeIfFoundIt(last.id, anchor: .bottom)
        container.layoutIfNeeded()
        let row = try #require(root.uiCollectNodes { $0.accessibilityIdentifier == "AdaEditor.ProjectTree.\(last.title)" }.first)
        let frame = row.visualAbsoluteFrame()
        let point = Point(x: frame.midX, y: frame.midY)
        container.onMouseEvent(MouseEvent(window: .empty, button: .left, mousePosition: point, phase: .began, modifierKeys: [], time: 0))
        container.onMouseEvent(MouseEvent(window: .empty, button: .left, mousePosition: point, phase: .ended, modifierKeys: [], time: 0.1))
        #expect(selection.id == last.id)
    }

    @Test("A retained scene stops hosted updates and resumes the same world on return")
    func retainedScenePausesHostedFrames() async throws {
        let host = AppWorlds(main: World(name: "RetainedSceneHost"))
        MainSchedulerPlugin().setup(in: host)
        host.insertResource(PreviewFrameCount())
        host.addSystem(CountPreviewFramesSystem.self)
        let preview = AppWorlds(main: World(name: "RetainedScene"))
        MainSchedulerPlugin().setup(in: preview)
        preview.insertResource(PreviewFrameCount())
        preview.addSystem(CountPreviewFramesSystem.self)
        let name = AppWorldName(rawValue: "RetainedScene")
        host.addSubworld(preview, by: name)
        try await host.build()
        let viewport = EditorSceneViewportModel()
        viewport.loadSceneWorld(preview.main, application: preview, onLoadingChanged: { _ in }, onLoaded: { _ in })
        defer { viewport.disconnect() }
        try await host.update()
        #expect(preview.main.getResource(PreviewFrameCount.self)?.count == 1)
        viewport.setPresentationActive(false)
        for _ in 0..<10 { await Task.yield() }
        // A native window becoming active must not wake a hidden document.
        preview.isHostedUpdateSuspended = false
        for _ in 0..<3 { try await host.update() }
        #expect(host.main.getResource(PreviewFrameCount.self)?.count == 4)
        #expect(preview.main.getResource(PreviewFrameCount.self)?.count == 1)
        #expect(host.getSubworldBuilder(by: name) === preview)
        viewport.setPresentationActive(true)
        for _ in 0..<10 { await Task.yield() }
        try await host.update()
        #expect(preview.main.getResource(PreviewFrameCount.self)?.count == 2)
        viewport.setPresentationActive(false)
        for _ in 0..<10 { await Task.yield() }
        viewport.disconnect()
        for _ in 0..<10 { await Task.yield() }
        try await host.update()
        #expect(preview.main.getResource(PreviewFrameCount.self)?.count == 3)
    }

    @Test("A fully started game keeps the footer static while unfinished work still animates", arguments: [true, false])
    func completedProgressDoesNotRedrawWorkspace(completed: Bool) async throws {
        let container = UIContainerView(rootView: EditorFooter(
            viewModel: EditorFooterViewModel(),
            activities: [.init(id: "run", kind: .run, title: "Run", fractionCompleted: completed ? 1 : 0.5)]
        ))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 24)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = container.consumeNeedsDisplayInHierarchy()
        try await Task.sleep(for: .milliseconds(100))
        container.update(0.1)
        #expect(container.consumeNeedsDisplayInHierarchy() == !completed)
    }

    @Test("Editor camera preserves authored IBL, background and disabled effects while navigating")
    func previewUsesSceneEnvironment() throws {
        let world = World()
        let display = world.spawn("SceneView_Camera") { Camera(); Transform() }
        var authoredCamera = Camera()
        authoredCamera.renderOrder = 5
        authoredCamera.backgroundColor = .red
        var authored = Environment3D(
            skybox: Skybox3D(isEnabled: false),
            screenSpaceReflection: ScreenSpaceReflection(isEnabled: false),
            imageBasedLighting: ImageBasedLightingSettings(asset: AssetHandle(ImageBasedLighting3D(
                irradiance: .whiteTexture, specular: .whiteTexture, brdf: .whiteTexture, specularLevels: 2
            )), intensity: 0.5, rotation: 0.3),
            antiAliasing: .fxaa
        )
        authored.localShadows.maximumLights = 2
        let sceneCamera = world.spawn("Authored camera") { authoredCamera; Transform(); authored }
        var lowerPriority = Camera()
        lowerPriority.renderOrder = 1
        let other = world.spawn("Other camera") { lowerPriority; Transform(); Environment3D() }
        let viewport = EditorSceneViewportModel()
        viewport.attachSceneWorld(world, loadResult: .init(
            entityCount: 2, warnings: [],
            entitiesByEditorID: ["camera": sceneCamera.id, "other": other.id],
            editorIDsByEntityID: [sceneCamera.id: "camera", other.id: "other"]
        ))
        viewport.setDisplayMode(.threeD)
        viewport.perspectiveBlend = 1
        viewport.setViewportSize(Size(width: 800, height: 600))
        viewport.threeDPosition = Vector3(1, 2, -5)
        viewport.applyCamera()
        let actual = try #require(display.components[Environment3D.self])
        #expect(actual.imageBasedLighting?.asset === authored.imageBasedLighting?.asset)
        #expect(actual.imageBasedLighting?.intensity == 0.5)
        #expect(actual.imageBasedLighting?.rotation == 0.3)
        #expect(actual.antiAliasing == .fxaa)
        #expect(actual.localShadows.maximumLights == 2)
        #expect(!actual.skybox.isEnabled)
        #expect(!actual.screenSpaceReflection.isEnabled)
        #expect(display.components[Camera.self]?.backgroundColor == .red)
        #expect(display.components[Transform.self]?.position == viewport.threeDPosition)
        // Switching to 2D must not lose the scene's 3D settings on return.
        viewport.setDisplayMode(.twoD)
        viewport.perspectiveBlend = 0
        viewport.applyCamera()
        viewport.setDisplayMode(.threeD)
        viewport.perspectiveBlend = 1
        viewport.applyCamera()
        #expect(display.components[Environment3D.self]?.imageBasedLighting?.intensity == 0.5)
        #expect(!authored.skybox.isEnabled)
    }

    @Test("A large hierarchy mounts visible rows and can select a distant row after scrolling")
    func hierarchyVirtualization() throws {
        var model = EditorSceneModel.default(projectName: "Large scene")
        for index in 0..<539 { _ = model.addEntity(name: "Entity \(index)", parentID: nil) }
        let last = try #require(model.entities.last)
        let document = EditorSceneDocument(
            id: "scene", title: "Main.ascn", relativePath: "Main.ascn", absolutePath: nil,
            content: try model.encodedYAML(), sceneModel: model, isDirty: false,
            loadSummary: .init(entityCount: model.entities.count, warnings: [])
        )
        let selection = HierarchySelection()
        let container = UIContainerView(rootView:
            EditorSceneHierarchySidebar(
                document: document, presentation: .embedded,
                onSelectEntity: { selection.id = $0 }, onToggleEntityExpanded: { _ in }
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 320, height: 400)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let root = container.viewTree.rootNode
        let mounted = root.uiCollectNodes { $0.accessibilityIdentifier?.hasPrefix("AdaEditor.SceneHierarchy.Select.") == true }
        #expect(!mounted.isEmpty && mounted.count < 60)
        #expect(root.uiCollectNodes { $0.accessibilityIdentifier == "AdaEditor.SceneHierarchy.Select.\(last.id)" }.isEmpty)
        let scroll = try #require(root.uiCollectNodes { $0 is ScrollViewNode }.first as? ScrollViewNode)
        scroll.scrollToViewNodeIfFoundIt(last.id, anchor: .bottom)
        container.layoutIfNeeded()
        let row = try #require(root.uiCollectNodes { $0.accessibilityIdentifier == "AdaEditor.SceneHierarchy.Select.\(last.id)" }.first)
        let frame = row.visualAbsoluteFrame()
        let point = Point(x: frame.midX, y: frame.midY)
        container.onMouseEvent(MouseEvent(window: .empty, button: .left, mousePosition: point, phase: .began, modifierKeys: [], time: 0))
        container.onMouseEvent(MouseEvent(window: .empty, button: .left, mousePosition: point, phase: .ended, modifierKeys: [], time: 0.1))
        #expect(selection.id == last.id)
    }
}

@MainActor
private final class HierarchySelection {
    var id: String?
}

struct PreviewFrameCount: Resource { var count = 0 }

@System
func CountPreviewFrames(_ counter: ResMut<PreviewFrameCount>) {
    counter.count += 1
}

private struct PreviewFrameProbePlugin: Plugin {
    func setup(in app: AppWorlds) {
        app.insertResource(PreviewFrameCount())
        app.addSystem(CountPreviewFramesSystem.self)
        let renderProbe = AppWorlds(main: World(name: "PreviewRenderProbe"))
        MainSchedulerPlugin().setup(in: renderProbe)
        renderProbe.insertResource(PreviewFrameCount())
        renderProbe.addSystem(CountPreviewFramesSystem.self)
        app.addSubworld(renderProbe, by: .init(rawValue: "PreviewRenderProbe"))
    }
}
