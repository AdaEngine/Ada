@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

/// Camera state for an asset viewer. Navigation never changes the authored model transform.
@MainActor
final class EditorModelPreviewCamera {
    static let fieldOfView = Angle.degrees(35)
    private weak var world: World?
    private var cameraID: Entity.ID?
    private var previousPointer: Point?
    private var activeButton: MouseButton?
    private var pressedKeys: Set<KeyCode> = []
    private var pinchScale: Float?
    private var lighting: AssetHandle<ImageBasedLighting3D>?
    private(set) var viewportSize = Size.zero
    private(set) var halfExtents = Vector3(1.5)
    private(set) var yaw: Float = -0.22
    private(set) var pitch: Float = 0.08
    private(set) var zoom: Float = 1
    private(set) var target = Vector3.zero

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
        let radius = max(0.1, halfExtents.length)
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
        camera.projection = .perspective(PerspectiveProjection(
            near: 0.01,
            far: max(100, cameraTransform().position.length + halfExtents.length * 4),
            fieldOfView: Self.fieldOfView,
            aspectRation: max(0.1, viewportSize.width / max(1, viewportSize.height))
        ))
        camera.backgroundColor = Color.fromHex(0x24282F)
        entity.components[Camera.self] = camera
        entity.components[Transform.self] = cameraTransform()
        entity.components[CameraRenderGraph.self] = CameraRenderGraph(subgraphLabel: .main3D, inputSlot: "view")
        entity.components[Environment3D.self] = Environment3D(
            skybox: Skybox3D(isEnabled: false),
            screenSpaceReflection: ScreenSpaceReflection(isEnabled: false),
            imageBasedLighting: lighting.map { ImageBasedLightingSettings(asset: $0) }
        )
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
                            for event in input.getInputEvents() { camera.handleInput(event) }
                        }
                        camera.update(deltaTime: Float(deltaTime))
                        model.pollGraphEvents(in: world)
                        world.getResource(EditorSkeleton3DOverlay.self)?.isEnabled = model.showsBones
                    }
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                Text(L10n.text("Drag: orbit · Middle drag: pan · Scroll: zoom\nRight drag: look · WASD: move · Q/E: down/up · Shift: faster"))
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .padding(16)
                    .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .mask(RoundedRectangleShape(cornerRadius: 10))
        }
        .onDisappear { camera.endNavigation() }
        .accessibilityIdentifier("AdaEditor.ModelPreview.Viewport")
    }
}
