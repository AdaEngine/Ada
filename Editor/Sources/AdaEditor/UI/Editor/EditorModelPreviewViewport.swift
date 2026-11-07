@_spi(AdaEngine) import AdaEngine
import Foundation
import Math
import Observation

/// Camera state for an asset viewer. Navigation never changes the authored model transform.
@Observable @MainActor
final class EditorModelPreviewCamera {
    static let fieldOfView = Angle.degrees(35)
    @ObservationIgnored private weak var world: World?
    @ObservationIgnored private var cameraID: Entity.ID?
    @ObservationIgnored private var previousPointer: Point?
    @ObservationIgnored private var activeButton: MouseButton?
    @ObservationIgnored private var pressedKeys: Set<KeyCode> = []
    @ObservationIgnored private var pinchScale: Float?
    @ObservationIgnored private var lighting: AssetHandle<ImageBasedLighting3D>?
    @ObservationIgnored private var selectionRadius: Float?
    @ObservationIgnored private(set) var viewportSize = Size.zero
    @ObservationIgnored private(set) var halfExtents = Vector3(1.5)
    @ObservationIgnored private(set) var yaw: Float = -0.22
    @ObservationIgnored private(set) var pitch: Float = 0.08
    @ObservationIgnored private(set) var zoom: Float = 1
    @ObservationIgnored private(set) var target = Vector3.zero
    var isOrthographic = false { didSet { applyCamera() } }
    var backgroundStyle = "dark" { didSet { applyCamera() } }
    var lightingIntensity: Float = 1 { didSet { applyCamera() } }
    var showsGrid = true
    var showsAxes = true

    func attach(to world: World, bounds: AABB, lighting: AssetHandle<ImageBasedLighting3D>? = nil) {
        endNavigation()
        self.world = world
        self.lighting = lighting
        halfExtents = bounds.halfExtents
        cameraID = nil
        applyCamera()
    }

    func setViewportSize(_ size: Size) {
        guard size.width > 0, size.height > 0, size != viewportSize else { return }
        viewportSize = size
        applyCamera()
    }

    func reset() {
        yaw = -0.22
        pitch = 0.08
        zoom = 1
        target = .zero
        selectionRadius = nil
        endNavigation()
        applyCamera()
    }

    func endNavigation() {
        world?.getResource(Input.self)?.releasePointerCapture()
        previousPointer = nil
        activeButton = nil
        pressedKeys.removeAll(keepingCapacity: true)
        pinchScale = nil
    }

    var distance: Float {
        let aspect = max(0.1, viewportSize.width / max(1, viewportSize.height))
        // Fit a sphere to keep tall and wide models inside the frame while orbiting.
        let radius = max(0.1, selectionRadius ?? halfExtents.length)
        let verticalHalfAngle = Self.fieldOfView.radians * 0.5
        let horizontalHalfAngle = Float(Foundation.atan(Foundation.tan(Double(verticalHalfAngle)) * Double(aspect)))
        return radius / Math.sin(min(verticalHalfAngle, horizontalHalfAngle)) * 1.12 * zoom
    }

    func cameraTransform() -> Transform {
        let offset = Vector3(Math.sin(yaw) * Math.cos(pitch), Math.sin(pitch), -Math.cos(yaw) * Math.cos(pitch)) * distance
        let eye = target + offset
        let front = -offset.normalized
        let right = Vector3(front.z, 0, -front.x).normalized
        let up = front.cross(right).normalized
        return Transform(matrix: Transform3D(columns: [Vector4(right, 0), Vector4(up, 0), Vector4(front, 0), Vector4(eye, 1)]))
    }

    func frameSelection(_ points: [Vector3]) {
        guard let first = points.first else { return }
        var lower = first
        var upper = first
        for point in points {
            lower = Vector3(min(lower.x, point.x), min(lower.y, point.y), min(lower.z, point.z))
            upper = Vector3(max(upper.x, point.x), max(upper.y, point.y), max(upper.z, point.z))
        }
        target = (lower + upper) * 0.5
        selectionRadius = max(0.1, (upper - lower).length * 0.65)
        zoom = 1
        applyCamera()
    }

    func project(_ position: Vector3) -> Vector2? {
        let clip = makeProjection().cameraProjection.makeClipView() * cameraTransform().matrix.inverse * Vector4(position, 1)
        guard clip.w > 0.000001, clip.z / clip.w >= 0, clip.z / clip.w <= 1 else { return nil }
        return Vector2((clip.x / clip.w + 1) * viewportSize.width * 0.5, (1 - clip.y / clip.w) * viewportSize.height * 0.5)
    }

    /// Projects the pointer onto a camera-facing plane through a world-space handle.
    func unproject(_ point: Point, atDepthOf position: Vector3) -> Vector3? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let matrix = makeProjection().cameraProjection.makeClipView() * cameraTransform().matrix.inverse
        let depth = matrix * Vector4(position, 1)
        guard depth.w > 1e-6 else { return nil }
        let clip = Vector4((point.x / viewportSize.width * 2 - 1) * depth.w,
                           (1 - point.y / viewportSize.height * 2) * depth.w, depth.z, depth.w)
        let world = matrix.inverse * clip
        guard world.w.isFinite, abs(world.w) > 1e-6 else { return nil }
        let value = world.xyz / world.w
        return value.x.isFinite && value.y.isFinite && value.z.isFinite ? value : nil
    }

    private func makeProjection() -> Projection {
        if isOrthographic {
            let height = 2 * distance * Math.tanf(Self.fieldOfView.radians * 0.5)
            return .orthographic(.init(near: 0.01, far: max(100, distance + halfExtents.length * 4),
                                      scale: max(0.1, viewportSize.height / max(0.01, height)), viewportSize: viewportSize))
        }
        return .perspective(.init(near: 0.01, far: max(100, cameraTransform().position.length + halfExtents.length * 4),
                                  fieldOfView: Self.fieldOfView, aspectRation: max(0.1, viewportSize.width / max(1, viewportSize.height))))
    }

    func orbit(by delta: Point) {
        yaw -= delta.x * 0.008
        pitch = max(-1.25, min(1.25, pitch + delta.y * 0.008))
        applyCamera()
    }

    func zoom(by delta: Float) {
        zoom = max(0.02, min(8, zoom * Float(Foundation.exp(Double(-delta * 0.08)))))
        applyCamera()
    }

    func pan(by delta: Point) {
        let transform = cameraTransform().matrix
        let scale = 2 * distance * Math.tanf(Self.fieldOfView.radians * 0.5) / max(1, viewportSize.height)
        target += (-transform[0].xyz * delta.x + transform[1].xyz * delta.y) * scale
        applyCamera()
    }

    func look(by delta: Point) {
        let eye = cameraTransform().position
        yaw -= delta.x * 0.008
        pitch = max(-1.55, min(1.55, pitch + delta.y * 0.008))
        let offset = Vector3(Math.sin(yaw) * Math.cos(pitch), Math.sin(pitch), -Math.cos(yaw) * Math.cos(pitch)) * distance
        target = eye - offset
        applyCamera()
    }

    func handleInput(_ event: any InputEvent) {
        if let mouse = event as? MouseEvent {
            if mouse.button == .scrollWheel {
                zoom(by: mouse.scrollDelta.y)
            } else if mouse.button == .left || mouse.button == .middle || mouse.button == .right {
                switch mouse.phase {
                case .began:
                    previousPointer = mouse.mousePosition
                    activeButton = mouse.button
                    if mouse.button == .right {
                        if mouse.modifierKeys.contains(.shift) { pressedKeys.insert(.shift) }
                        if let world, world.getResource(Input.self) != nil {
                            world.getRefResource(Input.self).wrappedValue.setMouseMode(.captured)
                        }
                    }
                case .changed:
                    guard activeButton == mouse.button, let previousPointer else { return }
                    let delta = mouse.motionDelta.map { Point($0.x, $0.y) } ?? (mouse.mousePosition - previousPointer)
                    if mouse.button == .middle || (mouse.button == .left && mouse.modifierKeys.contains(.shift)) {
                        pan(by: delta)
                    } else if mouse.button == .right {
                        look(by: delta)
                    } else {
                        orbit(by: delta)
                    }
                    self.previousPointer = mouse.mousePosition
                case .ended, .cancelled: endNavigation()
                }
            }
        } else if let key = event as? KeyEvent {
            if key.status == .up { pressedKeys.remove(key.keyCode) }
            else if key.keyCode == .escape { endNavigation() }
            else if activeButton == .right { pressedKeys.insert(key.keyCode) }
        } else if let touch = event as? TouchEvent {
            switch touch.phase {
            case .began: previousPointer = touch.location
            case .moved:
                if let previousPointer { orbit(by: touch.location - previousPointer) }
                previousPointer = touch.location
            case .ended, .cancelled: previousPointer = nil
            }
        } else if let pinch = event as? PinchEvent {
            if pinch.phase == .began { pinchScale = zoom }
            if let pinchScale, pinch.scale > 0 {
                zoom = max(0.02, min(8, pinchScale / pinch.scale))
                applyCamera()
            }
            if pinch.phase == .ended || pinch.phase == .cancelled { pinchScale = nil }
        }
    }

    func update(deltaTime: Float = 0) {
        if cameraID == nil { applyCamera() }
        guard activeButton == .right, deltaTime.isFinite, deltaTime > 0 else { return }
        let basis = cameraTransform().matrix
        var movement = Vector3.zero
        if pressedKeys.contains(.w) { movement += basis[2].xyz }
        if pressedKeys.contains(.s) { movement -= basis[2].xyz }
        if pressedKeys.contains(.d) { movement += basis[0].xyz }
        if pressedKeys.contains(.a) { movement -= basis[0].xyz }
        if pressedKeys.contains(.e) { movement += .up }
        if pressedKeys.contains(.q) { movement -= .up }
        guard movement.squaredLength > 0 else { return }
        let speed = max(distance, halfExtents.length * 0.5) * (pressedKeys.contains(.shift) ? 4 : 1)
        target += movement.normalized * speed * min(deltaTime, 0.1)
        applyCamera()
    }

    private func applyCamera() {
        guard let world else { return }
        if cameraID == nil {
            cameraID = world.getEntities().first { $0.name == "SceneView_Camera" && $0.components[Camera.self] != nil }?.id
        }
        guard let cameraID, let entity = world.getEntityByID(cameraID), var camera = entity.components[Camera.self] else { return }
        camera.projection = makeProjection()
        camera.backgroundColor = Color.fromHex(backgroundStyle == "light" ? 0xD9DDE2 : backgroundStyle == "gray" ? 0x62656B : 0x24282F)
        entity.components[Camera.self] = camera
        entity.components[Transform.self] = cameraTransform()
        entity.components[CameraRenderGraph.self] = CameraRenderGraph(subgraphLabel: .main3D, inputSlot: "view")
        entity.components[Environment3D.self] = Environment3D(
            skybox: Skybox3D(isEnabled: false),
            screenSpaceReflection: ScreenSpaceReflection(isEnabled: false),
            imageBasedLighting: lighting.map { ImageBasedLightingSettings(asset: $0, intensity: max(0, min(8, lightingIntensity))) }
        )
        for light in world.getEntities() {
            guard var component = light.components[DirectionalLightComponent.self] else { continue }
            let base: Float = light.name == "Preview key light" ? 2.8 : 2.2
            component.intensity = base * max(0, min(8, lightingIntensity))
            light.components[DirectionalLightComponent.self] = component
        }
    }
}

struct EditorModelPreviewViewport: View {
    let model: EditorModelAssetPreviewModel
    let camera: EditorModelPreviewCamera
    @Environment(\.theme) private var theme

    static func configure(_ app: AppWorlds, model: EditorModelAssetPreviewModel, camera: EditorModelPreviewCamera) {
        app.addPlugin(EventsPlugin())
            .addPlugin(TransformPlugin())
            .addPlugin(InputPlugin(actions: []))
            .addPlugin(RenderWorldPlugin())
            .addPlugin(CameraPlugin())
            .addPlugin(AssetsPlugin(filePath: #filePath))
            .addPlugin(VisibilityPlugin())
            .addPlugin(Model3DPlugin())
            .addPlugin(Core3DPlugin())
            .addPlugin(UpscalePlugin())
        app.addPlugin(EditorSkeleton3DPlugin())
        guard let asset = model.asset else { return }
        let root = asset.instantiate(in: app.main)
        root.components[Transform.self] = model.normalizationTransform
        let lights = app.main.spawn("Preview lighting") { Transform() }
        let key = app.main.spawn("Preview key light") {
            Transform(rotation: Quat.euler([-0.55, -0.4, 0]))
            DirectionalLightComponent(radiance: Vector3(1, 0.96, 0.9), intensity: 2.8, castShadows: false)
        }
        let fill = app.main.spawn("Preview fill light") {
            Transform(rotation: Quat.euler([0.55, .pi - 0.4, 0]))
            DirectionalLightComponent(radiance: Vector3(0.9, 0.95, 1), intensity: 2.2, castShadows: false)
        }
        lights.addChild(key)
        lights.addChild(fill)
        camera.attach(to: app.main, bounds: model.normalizedBounds, lighting: model.previewLighting)
        model.bind(to: app.main)
    }

    var body: some View {
        GeometryReader { geometry in
            // AdaUI result builders require a declaration before view content.
            // swiftlint:disable:next redundant_discardable_let
            let _ = camera.setViewportSize(geometry.size)
            ZStack(anchor: .bottomLeading) {
                SceneView(
                    updatesWhenWindowInactive: false,
                    make: { app in
                        Self.configure(app, model: model, camera: camera)
                    },
                    updateContent: { world, deltaTime in
                        if let input = world.getResource(Input.self) {
                            for event in input.getInputEvents() {
                                if model.onModifierInput?(event, camera) == true { continue }
                                camera.handleInput(event)
                                model.handleBoneSelection(event, camera: camera)
                            }
                        }
                        camera.update(deltaTime: Float(deltaTime))
                        model.pollGraphEvents(in: world)
                        world.getResource(EditorSkeleton3DOverlay.self)?.isEnabled = model.showsBones
                        world.getResource(EditorSkeleton3DOverlay.self)?.selectedNodes = model.selectedNodeIndices
                        world.getResource(EditorSkeleton3DOverlay.self)?.showsGrid = camera.showsGrid
                        world.getResource(EditorSkeleton3DOverlay.self)?.showsAxes = camera.showsAxes
                        world.getResource(EditorSkeleton3DOverlay.self)?.gridHeight = model.normalizedBounds.min.y
                        world.getResource(EditorSkeleton3DOverlay.self)?.modifierHandles = model.modifierHandleSegments()
                    }
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                if geometry.size.width >= 360, geometry.size.height >= 240 {
                    Text(L10n.text("Drag: orbit · Middle drag: pan · Scroll: zoom\nRight drag: look · WASD: move · Q/E: down/up · Shift: faster"))
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .padding(16)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .mask(RoundedRectangleShape(cornerRadius: 10))
        }
        .onDisappear { camera.endNavigation() }
        .accessibilityIdentifier("AdaEditor.ModelPreview.Viewport")
    }
}
