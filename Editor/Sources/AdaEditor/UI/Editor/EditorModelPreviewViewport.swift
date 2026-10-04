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
    private var pinchScale: Float?
    private(set) var viewportSize = Size.zero
    private(set) var halfExtents = Vector3(1.5)
    private(set) var yaw: Float = -0.22
    private(set) var pitch: Float = 0.08
    private(set) var zoom: Float = 1

    func attach(to world: World, bounds: AABB) {
        self.world = world
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
        previousPointer = nil
        applyCamera()
    }

    var distance: Float {
        let aspect = max(0.1, viewportSize.width / max(1, viewportSize.height))
        // Fit a sphere to keep tall and wide models inside the frame while orbiting.
        let radius = max(0.1, halfExtents.length)
        let verticalHalfAngle = Self.fieldOfView.radians * 0.5
        let horizontalHalfAngle = Math.atan(Math.tan(verticalHalfAngle) * aspect)
        return radius / Math.sin(min(verticalHalfAngle, horizontalHalfAngle)) * 1.12 * zoom
    }

    func cameraTransform() -> Transform {
        let eye = Vector3(Math.sin(yaw) * Math.cos(pitch), Math.sin(pitch), -Math.cos(yaw) * Math.cos(pitch)) * distance
        let front = -eye.normalized
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
        zoom = max(0.45, min(4, zoom * Float(Foundation.exp(Double(-delta * 0.08)))))
        applyCamera()
    }

    func handleInput(_ event: any InputEvent) {
        if let mouse = event as? MouseEvent {
            if mouse.button == .scrollWheel {
                zoom(by: mouse.scrollDelta.y)
            } else if mouse.button == .left || mouse.button == .middle {
                switch mouse.phase {
                case .began: previousPointer = mouse.mousePosition
                case .changed:
                    if let previousPointer { orbit(by: mouse.mousePosition - previousPointer) }
                    previousPointer = mouse.mousePosition
                case .ended, .cancelled: previousPointer = nil
                }
            }
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
                zoom = max(0.45, min(4, pinchScale / pinch.scale))
                applyCamera()
            }
            if pinch.phase == .ended || pinch.phase == .cancelled { pinchScale = nil }
        }
    }

    func update() {
        if cameraID == nil { applyCamera() }
    }

    private func applyCamera() {
        guard let world else { return }
        if cameraID == nil {
            cameraID = world.getEntities().first { $0.name == "SceneView_Camera" && $0.components[Camera.self] != nil }?.id
        }
        guard let cameraID, let entity = world.getEntityByID(cameraID), var camera = entity.components[Camera.self] else { return }
        camera.projection = .perspective(PerspectiveProjection(
            near: 0.01,
            far: 100,
            fieldOfView: Self.fieldOfView,
            aspectRation: max(0.1, viewportSize.width / max(1, viewportSize.height))
        ))
        camera.backgroundColor = Color.fromHex(0x24282F)
        entity.components[Camera.self] = camera
        entity.components[Transform.self] = cameraTransform()
        entity.components[CameraRenderGraph.self] = CameraRenderGraph(subgraphLabel: .main3D, inputSlot: "view")
        entity.components[Environment3D.self] = Environment3D(
            skybox: Skybox3D(isEnabled: false),
            screenSpaceReflection: ScreenSpaceReflection(isEnabled: false)
        )
    }
}

struct EditorModelPreviewViewport: View {
    let model: EditorModelAssetPreviewModel
    let camera: EditorModelPreviewCamera
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            // AdaUI result builders require a declaration before view content.
            // swiftlint:disable:next redundant_discardable_let
            let _ = camera.setViewportSize(geometry.size)
            ZStack(anchor: .bottomLeading) {
                SceneView(
                    make: { app in
                        app.addPlugin(TransformPlugin())
                            .addPlugin(InputPlugin(actions: []))
                            .addPlugin(RenderWorldPlugin())
                            .addPlugin(CameraPlugin())
                            .addPlugin(AssetsPlugin(filePath: #filePath))
                            .addPlugin(VisibilityPlugin())
                            .addPlugin(Model3DPlugin())
                            .addPlugin(Core3DPlugin(includes2D: true))
                            .addPlugin(UpscalePlugin())
                        guard let asset = model.asset else { return }
                        let root = asset.instantiate(in: app.main)
                        root.components[Transform.self] = model.normalizationTransform
                        app.main.spawn("Preview key light") {
                            Transform(rotation: Quat(axis: Vector3(0, 1, 0), angle: -0.4))
                            DirectionalLightComponent(radiance: Vector3(1, 0.96, 0.9), intensity: 4, castShadows: false)
                        }
                        camera.attach(to: app.main, bounds: model.normalizedBounds)
                        model.bind(to: app.main)
                    },
                    updateContent: { world, _ in
                        if let input = world.getResource(Input.self) {
                            for event in input.getInputEvents() { camera.handleInput(event) }
                        }
                        camera.update()
                    }
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                Text("Drag to orbit · Scroll to zoom")
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .padding(16)
                    .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .mask(RoundedRectangleShape(cornerRadius: 10))
        }
        .accessibilityIdentifier("AdaEditor.ModelPreview.Viewport")
    }
}
