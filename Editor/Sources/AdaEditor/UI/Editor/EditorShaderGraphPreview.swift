@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

@Observable @MainActor final class EditorShaderGraphPreview {
    private(set) var material: ShaderGraphMaterial?
    private(set) var error: String?
    private(set) var errorNode: String?
    private(set) var isCompiling = false
    private(set) var isStale = false
    private(set) var revision: UInt64 = 0
    var isPlaying = true
    var shape = "sphere"
    var selectedModel: EditorModelAssetPreviewModel?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastValidMaterial: ShaderGraphMaterial?
    @ObservationIgnored private var validatedSource: String?
    @ObservationIgnored var elapsed: Float = 0

    func schedule(_ graph: ShaderGraph?, basePath: String?) {
        task?.cancel()
        generation &+= 1
        let token = generation
        isCompiling = true
        isStale = material != nil
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard let graph else { throw EditorShaderGraphFileError.unavailable }
                let source = try await Self.validate(graph, validatedSource: self?.validatedSource)
                try Task.checkCancellation()
                guard let self, self.generation == token else {
                    return
                }
                let root = basePath.map { EditorSceneViewportView.uiProjectRoot(from: URL(fileURLWithPath: $0).deletingLastPathComponent()) }
                let assets = root.flatMap { root in
                    (try? ProjectSystem.loadProject(at: root)).map { root.appendingPathComponent($0.paths.assets ?? "Assets").path }
                }
                let next = try ShaderGraphMaterial(source: .init(graph: graph), resourceBasePath: basePath, resourceRootPath: assets)
                self.validatedSource = source
                self.material = next
                self.revision &+= 1
                self.error = nil
                self.errorNode = nil
                self.isStale = false
                self.isCompiling = false
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else {
                    return
                }
                self.errorNode = (error as? ShaderGraphDiagnostic)?.nodeID ?? (error as? ShaderGraphCompilationError)?.nodeID
                self.error = L10n.text("Preview could not compile. The last valid material is kept.")
                self.isStale = self.material != nil
                self.isCompiling = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isCompiling = false
    }

    func restart() {
        elapsed = 0
        material?.setTime(0)
    }

    @concurrent private static func validate(_ graph: ShaderGraph, validatedSource: String?) async throws -> String {
        let program = try graph.compileGLSL()
        if program.source != validatedSource { try program.validateGLSL() }
        return program.source
    }

    func checkDeviceError() {
        guard let issue = material?.compilationError else {
            if material?.hasPreparedPipeline == true { lastValidMaterial = material }
            return
        }
        let diagnostic = material?.program.diagnostic(for: issue)
        errorNode = diagnostic?.nodeID
        error = L10n.text("The renderer could not prepare this graph material.")
        isStale = true
        if let lastValidMaterial, material !== lastValidMaterial {
            material = lastValidMaterial
            revision &+= 1
        }
    }
}

/// Preview world uses the regular Sprite and PBR pipelines, including their graph variants.
struct EditorShaderGraphViewport: View {
    let model: EditorShaderGraphPreview
    @State private var camera = EditorModelPreviewCamera()
    @State private var driver = EditorShaderGraphPreviewDriver()

    var body: some View {
        GeometryReader { geometry in
            // swiftlint:disable:next redundant_discardable_let
            let _ = camera.setViewportSize(geometry.size)
            SceneView(
                updatesWhenWindowInactive: false,
                make: { app in Self.configure(app, model: model, camera: camera) },
                updateContent: { world, deltaTime in driver.update(world: world, model: model, camera: camera, deltaTime: Float(deltaTime)) }
            ).frame(width: geometry.size.width, height: geometry.size.height)
        }.accessibilityIdentifier("AdaEditor.ShaderGraph.Preview")
    }

    static func configure(_ app: AppWorlds, model: EditorShaderGraphPreview, camera: EditorModelPreviewCamera) {
        app.addPlugin(EventsPlugin()).addPlugin(TransformPlugin()).addPlugin(InputPlugin(actions: [])).addPlugin(RenderWorldPlugin()).addPlugin(CameraPlugin()).addPlugin(AssetsPlugin(filePath: #filePath)).addPlugin(
            VisibilityPlugin()
        ).addPlugin(UpscalePlugin())
        if model.material?.program.target == .sprite {
            app.addPlugin(SpritePlugin()).addPlugin(Core2DPlugin())
            var sprite = Sprite()
            sprite.graphMaterial = model.material
            app.main.spawn("Graph sprite") {
                Transform(scale: [160, 160, 1])
                sprite
            }
        } else {
            app.addPlugin(Model3DPlugin()).addPlugin(Core3DPlugin())
            let device = unsafe RenderEngine.shared.renderDevice
            if let selected = model.selectedModel, let asset = selected.asset {
                let root = asset.instantiate(in: app.main)
                root.components[Transform.self] = selected.normalizationTransform
                for entity in app.main.getEntities() {
                    if var mesh = entity.components[Mesh3DComponent.self] {
                        mesh.materials = mesh.materials.map { _ in
                            let value = PBRMaterial()
                            value.graphMaterial = model.material
                            return value
                        }
                        entity.components[Mesh3DComponent.self] = mesh
                    }
                }
                camera.attach(to: app.main, bounds: selected.normalizedBounds)
            } else {
                let material = PBRMaterial()
                material.graphMaterial = model.material
                let plane = model.shape == "plane"
                let mesh = plane ? Mesh.generatePlane(size: [2, 2], renderDevice: device) : Mesh.generateSphere(radius: 1, renderDevice: device)
                app.main.spawn("Graph surface") {
                    Transform(rotation: plane ? Quat.euler([-Float.pi / 2, 0, 0]) : .identity)
                    Mesh3DComponent(mesh: mesh, materials: [material])
                }
                camera.attach(to: app.main, bounds: AABB(center: .zero, halfExtents: [1, 1, 1]))
            }
            app.main.spawn("Graph preview light") {
                Transform(rotation: Quat.euler([-0.6, 0.5, 0]))
                DirectionalLightComponent(radiance: [1, 0.96, 0.9], intensity: 4, castShadows: false)
            }
        }
    }
}

@MainActor final class EditorShaderGraphPreviewDriver {
    private var revision: UInt64?
    private weak var world: World?

    func update(world: World, model: EditorShaderGraphPreview, camera: EditorModelPreviewCamera, deltaTime: Float) {
        if self.world !== world {
            self.world = world
            revision = nil
        }
        model.checkDeviceError()
        if model.isPlaying, deltaTime.isFinite { model.elapsed += max(0, min(0.1, deltaTime)) }
        model.material?.setTime(model.elapsed)
        if revision != model.revision {
            for entity in world.getEntities() {
                if var sprite = entity.components[Sprite.self] {
                    sprite.graphMaterial = model.material
                    entity.components[Sprite.self] = sprite
                }
                if let mesh = entity.components[Mesh3DComponent.self] { for material in mesh.materials { (material as? PBRMaterial)?.graphMaterial = model.material } }
            }
            revision = model.revision
        }
        if model.material?.program.target == .pbrSurface {
            if let input = world.getResource(Input.self) { for event in input.getInputEvents() { camera.handleInput(event) } }
            camera.update(deltaTime: deltaTime)
        }
    }
}
