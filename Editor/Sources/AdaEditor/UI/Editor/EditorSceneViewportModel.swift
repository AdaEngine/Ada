@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

enum EditorSceneViewportDisplayMode: String {
    case twoD = "2D"
    case threeD = "3D"
}

enum EditorSceneViewportTool: String, CaseIterable {
    case select = "Select"
    case translate = "Move"
    case scale = "Scale"
    case rotate = "Rotate"
}

@MainActor
final class EditorSceneViewportModel {
    static let twoDCameraDepth: Float = -10
    private static let maximumTwoDZoom: Float = 150

    private weak var world: World?
    private var cameraEntityID: Entity.ID?
    var displayMode: EditorSceneViewportDisplayMode = .twoD
    var viewportSize: Size = .zero
    private var entitiesByEditorID: [String: Entity.ID] = [:]
    private var editorIDsByEntityID: [Entity.ID: String] = [:]
    private var sceneContent = ""
    private(set) var sceneModel: EditorSceneModel?
    private var sceneSourceURL: URL?
    private var sceneResourceRootURL: URL?
    private var scriptableObjectCatalog: [EditorScriptableObjectDescriptor] = []
    private(set) var selectedEditorID: String?
    private(set) var activeTool: EditorSceneViewportTool = .translate
    private(set) var hoveredGizmoHandle: EditorTransformGizmo.Handle?
    var activeGizmoHandle: EditorTransformGizmo.Handle? { transformDrag?.interaction.handle }

    var twoDCenter = Vector2.zero
    var twoDZoom: Float = 1
    var threeDPosition = Vector3(0, 6, -10)
    var threeDYaw: Float = 0
    var threeDPitch: Float = -0.42
    var perspectiveBlend: Float = 0

    private var lastPinchScale: Float?
    private var pressedKeys: Set<KeyCode> = []
    private var lastMousePosition: Point?
    private var mouseDownPosition: Point?
    private var transformDrag: TransformDrag?
    private var transformInspectorUpdateTask: Task<Void, Never>?
    private var suppressSelectionOnPointerEnd = false
    private var isTwoDPanning = false
    private var isThreeDRotating = false
    private var lastTouchPosition: Point?
    private var touchDownPosition: Point?

    var onSelectEntity: ((String?) -> Void)?
    private var onSelectionChanged: ((EditorInspectorSidebarViewModel.SelectedEntity?) -> Void)?
    private var onDocumentContentChanged: ((String) -> Void)?
    private var onTransformChanged: ((String, EditorComponentPayload) -> Void)?

    private struct TransformDrag {
        var editorID: String
        var startContent: String
        var startPayload: EditorComponentPayload
        var interaction: EditorTransformGizmo.Drag
    }

    struct CameraState {
        var projection: Projection
        var transform: Transform
        var renderGraphLabel: RenderGraph.Label
    }

    @discardableResult
    func configure(
        sceneContent: String,
        sourceURL: URL? = nil,
        resourceRootURL: URL? = nil,
        scriptableObjectCatalog: [EditorScriptableObjectDescriptor] = [],
        onSelectionChanged: @escaping (EditorInspectorSidebarViewModel.SelectedEntity?) -> Void,
        onDocumentContentChanged: @escaping (String) -> Void,
        onTransformChanged: ((String, EditorComponentPayload) -> Void)? = nil
    ) -> EditorSceneRuntimeLoadResult? {
        let contentChanged = self.sceneContent != sceneContent
        self.sceneSourceURL = sourceURL
        self.sceneResourceRootURL = resourceRootURL
        self.scriptableObjectCatalog = scriptableObjectCatalog
        self.onSelectionChanged = onSelectionChanged
        self.onDocumentContentChanged = onDocumentContentChanged
        self.onTransformChanged = onTransformChanged
        self.onSelectEntity = { [weak self] editorID in
            self?.selectEntity(editorID)
        }

        // A live drag updates the runtime/Inspector; publish one document edit on release.
        // Redraws still carry the last published document until then.
        if let transformDrag, sceneContent == transformDrag.startContent {
            return nil
        }
        guard contentChanged else {
            return nil
        }
        cancelTransformInspectorUpdate()
        self.sceneContent = sceneContent
        transformDrag = nil
        hoveredGizmoHandle = nil
        sceneModel = EditorSceneFileLoader.model(from: sceneContent)
        guard let model = sceneModel else {
            return nil
        }
        selectedEditorID = model.editor?.selectedEntity
        let loadResult = reloadSceneRuntimeIfReady()
        onSelectionChanged(selectedEntityViewModel(editorID: selectedEditorID, model: model))
        return loadResult
    }

    func disconnect() {
        lastPinchScale = nil
        cancelTransformInspectorUpdate()
        world = nil
        cameraEntityID = nil
        entitiesByEditorID.removeAll()
        editorIDsByEntityID.removeAll()
        pressedKeys.removeAll()
        lastMousePosition = nil
        mouseDownPosition = nil
        transformDrag = nil
        isTwoDPanning = false
        isThreeDRotating = false
        lastTouchPosition = nil
        touchDownPosition = nil
        hoveredGizmoHandle = nil
        onSelectEntity = nil
        onSelectionChanged = nil
        onTransformChanged = nil
        onDocumentContentChanged = nil
    }

    func attachSceneWorld(_ world: World, loadResult: EditorSceneRuntimeLoadResult) {
        self.world = world
        self.entitiesByEditorID = loadResult.entitiesByEditorID
        self.editorIDsByEntityID = loadResult.editorIDsByEntityID
        cameraEntityID = findCameraEntity(in: world)?.id
        applyCamera()
    }

    @discardableResult
    func reloadSceneRuntimeIfReady() -> EditorSceneRuntimeLoadResult? {
        guard let world else {
            return nil
        }

        let previousEntityIDs = Set(entitiesByEditorID.values)
        entitiesByEditorID.removeAll()
        editorIDsByEntityID.removeAll()
        transformDrag = nil

        for entityID in previousEntityIDs {
            guard entityID != cameraEntityID else {
                continue
            }
            world.removeEntity(entityID, recursively: true)
        }
        world.flush()

        let result = EditorSceneFileLoader.load(
            content: sceneContent,
            into: world,
            loadsScriptableObjects: false,
            sourceURL: sceneSourceURL,
            resourceRootURL: sceneResourceRootURL
        )
        entitiesByEditorID = result.entitiesByEditorID
        editorIDsByEntityID = result.editorIDsByEntityID
        cameraEntityID = findCameraEntity(in: world)?.id
        applyCamera()
        return result
    }

    func setDisplayMode(_ mode: EditorSceneViewportDisplayMode) {
        lastPinchScale = nil
        guard mode != displayMode else {
            return
        }

        endTransformDrag(cancelled: true)
        hoveredGizmoHandle = nil
        displayMode = mode
        lastMousePosition = nil
        isTwoDPanning = false
        isThreeDRotating = false
        applyCamera()
    }

    func setActiveTool(_ tool: EditorSceneViewportTool) {
        guard tool != activeTool else {
            return
        }
        endTransformDrag(cancelled: true)
        hoveredGizmoHandle = nil
        activeTool = tool
    }

    func setViewportSize(_ size: Size) {
        guard size.width > 0 && size.height > 0 && size != viewportSize else {
            return
        }

        viewportSize = size
        applyCamera()
    }

    func update(deltaTime: Float) -> Bool {
        var didChange = advancePerspectiveTransition(deltaTime: deltaTime)
        // SceneView creates its camera after the scene-loading callback. Bind it
        // on the first update where it exists, even if the user has not moved.
        if cameraEntityID == nil, cameraEntity() != nil {
            didChange = true
        }

        if displayMode == .threeD, transformDrag == nil {
            let movement = movementVector()
            if movement.squaredLength > 0 {
                let speedMultiplier: Float = pressedKeys.contains(.shift) ? 4 : 1
                let speed = deltaTime * 8 * speedMultiplier
                threeDPosition += movement.normalized * speed
                didChange = true
            }
        }

        if didChange {
            applyCamera()
        }
        return didChange
    }

    var perspectiveTransitionProgress: Float {
        perspectiveBlend
    }

    var isPerspectiveTransitionActive: Bool {
        displayMode == .threeD ? perspectiveBlend < 1 : perspectiveBlend > 0
    }

    func handleInput(_ event: any InputEvent) -> Bool {
        switch event {
        case let pinchEvent as PinchEvent:
            return handlePinchEvent(pinchEvent)
        case let keyEvent as KeyEvent:
            return handleKeyEvent(keyEvent)
        case let mouseEvent as MouseEvent:
            return handleMouseEvent(mouseEvent)
        case let touchEvent as TouchEvent:
            return handleTouchEvent(touchEvent)
        default:
            return false
        }
    }

    func drawGrid(in context: inout UIGraphicsContext, size: Size, theme: Theme) {
        let blend = smoothPerspectiveBlend
        if blend < 1 {
            draw2DGrid(in: &context, size: size, theme: theme, opacity: 1 - blend)
        }
        if blend > 0 {
            draw3DGrid(in: &context, size: size, theme: theme, opacity: blend)
        }
    }

    func drawGizmos(in context: inout UIGraphicsContext, size: Size, theme: Theme) {
        if let world {
            for icon in EditorGizmoOverlayModel.icons(in: world, editorIDsByEntityID: editorIDsByEntityID) {
                guard let point = projectedPoint(from: icon.position, size: size) else {
                    continue
                }
                let radius = max(5, min(18, icon.size * 8))
                let rect = Rect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                context.fill(CircleShape().path(in: rect), with: color(for: icon, theme: theme).opacity(icon.isExplicit ? 0.86 : 0.58))
            }
        }

        guard let model = sceneModel else {
            return
        }

        let selectedPoint = selectedEditorID.flatMap { gizmoWorldMatrix(for: $0) }.flatMap { project($0.origin, size: size) }
        for entity in model.entities {
            let isSelected = entity.id == selectedEditorID
            guard
                let payload = entity.components[EditorBuiltInComponentType.transform],
                let point = isSelected ? selectedPoint : projectedPoint(from: payload, size: size)
            else {
                continue
            }
            let radius: Float = isSelected ? 6 : 4
            drawViewportMarker(
                at: point,
                radius: radius,
                color: isSelected ? theme.editorColors.purple : theme.editorColors.blue.opacity(0.72),
                in: &context
            )
        }
        if let gizmo = transformGizmo() {
            gizmo.draw(in: &context, highlighted: activeGizmoHandle ?? hoveredGizmoHandle)
        }
    }

    private func color(for icon: EditorGizmoOverlayModel.Icon, theme: Theme) -> Color {
        if let color = icon.color {
            return color
        }
        switch icon.kind {
        case .transform:
            return theme.editorColors.blue
        case .light:
            return .yellow
        case .camera:
            return .green
        case .audio:
            return theme.editorColors.purple
        case .custom:
            return theme.editorColors.text
        }
    }

    func updateSelectedGizmo(_ gizmo: EditorGizmo) {
        guard let selectedEditorID else {
            return
        }

        do {
            sceneContent = try EditorSceneYAMLDocument.upsertGizmo(gizmo, entityID: selectedEditorID, in: sceneContent)
            onDocumentContentChanged?(sceneContent)
            if let model = EditorSceneFileLoader.model(from: sceneContent) {
                sceneModel = model
                onSelectionChanged?(selectedEntityViewModel(editorID: selectedEditorID, model: model))
            }
        } catch {
            assertionFailure(error.localizedDescription)
        }
    }

    var statusSuffix: String {
        switch displayMode {
        case .twoD:
            "2D zoom \(formatted(twoDZoom))"
        case .threeD:
            "3D fly \(formatted(threeDPosition.x)), \(formatted(threeDPosition.y)), \(formatted(threeDPosition.z))"
        }
    }
}

extension EditorSceneViewportModel {
    func handleKeyEvent(_ event: KeyEvent) -> Bool {
        switch event.status {
        case .down:
            if event.keyCode == .escape, transformDrag != nil {
                endTransformDrag(cancelled: true)
                return true
            }
            pressedKeys.insert(event.keyCode)
        case .up:
            pressedKeys.remove(event.keyCode)
        }

        switch event.keyCode {
        case .space,
            .w,
            .a,
            .s,
            .d,
            .q,
            .e,
            .shift:
            return true
        default:
            return false
        }
    }

    func handleMouseEvent(_ event: MouseEvent) -> Bool {
        if event.button == .scrollWheel {
            return transformDrag != nil || handleScroll(event)
        }
        if event.phase == .changed, transformDrag == nil, !isTwoDPanning, !isThreeDRotating {
            let handle = transformGizmo()?.hitTest(event.mousePosition)
            if handle != hoveredGizmoHandle {
                hoveredGizmoHandle = handle
                return true
            }
        }

        switch displayMode {
        case .twoD:
            return handle2DMouse(event)
        case .threeD:
            return handle3DMouse(event)
        }
    }

    func handle2DMouse(_ event: MouseEvent) -> Bool {
        let wantsPan = event.button == .middle || (pressedKeys.contains(.space) && event.button == .left)

        switch event.phase {
        case .began:
            suppressSelectionOnPointerEnd = false
            mouseDownPosition = event.mousePosition
            if !pressedKeys.contains(.space), beginTransformDragIfNeeded(at: event.mousePosition, button: event.button) {
                return true
            }
            guard wantsPan else {
                return event.button == .left
            }
            isTwoDPanning = true
            lastMousePosition = event.mousePosition
            return true
        case .changed:
            if updateTransformDrag(to: event.mousePosition) {
                return true
            }
            guard isTwoDPanning, let lastMousePosition else {
                return false
            }
            pan2D(byScreenDelta: event.mousePosition - lastMousePosition)
            self.lastMousePosition = event.mousePosition
            return true
        case .ended,
            .cancelled:
            defer {
                isTwoDPanning = false
                lastMousePosition = nil
                mouseDownPosition = nil
                endTransformDrag(cancelled: event.phase == .cancelled)
                suppressSelectionOnPointerEnd = false
            }
            if suppressSelectionOnPointerEnd {
                return true
            }
            if transformDrag != nil {
                if event.phase == .ended {
                    _ = updateTransformDrag(to: event.mousePosition)
                }
                return true
            }
            guard event.phase == .ended, !isTwoDPanning, event.button == .left, isClickEnd(at: event.mousePosition) else {
                return isTwoDPanning
            }
            onSelectEntity?(pick2D(at: event.mousePosition))
            return true
        }
    }

    func handle3DMouse(_ event: MouseEvent) -> Bool {
        switch event.phase {
        case .began:
            suppressSelectionOnPointerEnd = false
            mouseDownPosition = event.mousePosition
            if !pressedKeys.contains(.space), beginTransformDragIfNeeded(at: event.mousePosition, button: event.button) {
                return true
            }
            guard event.button == .right else {
                return event.button == .left
            }
            isThreeDRotating = true
            lastMousePosition = event.mousePosition
            return true
        case .changed:
            if updateTransformDrag(to: event.mousePosition) {
                return true
            }
            guard isThreeDRotating, let lastMousePosition else {
                return false
            }
            rotate3D(by: event.mousePosition - lastMousePosition)
            self.lastMousePosition = event.mousePosition
            return true
        case .ended,
            .cancelled:
            defer {
                isThreeDRotating = false
                lastMousePosition = nil
                mouseDownPosition = nil
                endTransformDrag(cancelled: event.phase == .cancelled)
                suppressSelectionOnPointerEnd = false
            }
            if suppressSelectionOnPointerEnd {
                return true
            }
            if transformDrag != nil {
                if event.phase == .ended {
                    _ = updateTransformDrag(to: event.mousePosition)
                }
                return true
            }
            guard event.phase == .ended, !isThreeDRotating, event.button == .left, isClickEnd(at: event.mousePosition) else {
                return isThreeDRotating
            }
            onSelectEntity?(pick3D(at: event.mousePosition))
            return true
        }
    }

    func isClickEnd(at position: Point) -> Bool {
        guard let mouseDownPosition else {
            return true
        }
        return Vector2(position.x - mouseDownPosition.x, position.y - mouseDownPosition.y).squaredLength < 16
    }

    func beginTransformDragIfNeeded(at position: Point, button: MouseButton) -> Bool {
        guard
            button == .left,
            let selectedEditorID,
            let entity = sceneModel?.entities.first(where: { $0.id == selectedEditorID }),
            let payload = entity.components[EditorBuiltInComponentType.transform],
            let transform = try? EditorComponentPayloadDecoder.decode(Transform.self, payload: payload) as? Transform,
            let gizmo = transformGizmo(), let handle = gizmo.hitTest(position)
        else {
            return false
        }
        transformDrag = TransformDrag(
            editorID: selectedEditorID,
            startContent: sceneContent,
            startPayload: payload,
            interaction: EditorTransformGizmo.Drag(gizmo: gizmo, handle: handle, start: position, transform: transform)
        )
        hoveredGizmoHandle = handle
        return true
    }

    func updateTransformDrag(to position: Point) -> Bool {
        guard var drag = transformDrag else {
            return false
        }
        let transform = drag.interaction.updated(at: position)
        transformDrag = drag
        var payload = drag.startPayload
        if transform != drag.interaction.transform {
            switch drag.interaction.gizmo.tool {
            case .translate:
                payload["position"] = .array([transform.position.x, transform.position.y, transform.position.z].map { .double(Double($0)) })
            case .scale:
                payload["scale"] = .array([transform.scale.x, transform.scale.y, transform.scale.z].map { .double(Double($0)) })
            case .rotate:
                payload["rotation"] = .array([transform.rotation.x, transform.rotation.y, transform.rotation.z, transform.rotation.w].map { .double(Double($0)) })
            case .select: break
            }
        }
        applyTransformPayload(payload, editorID: drag.editorID)
        return true
    }

    private func applyTransformPayload(_ payload: EditorComponentPayload, editorID: String) {
        guard
            var model = sceneModel, let index = model.entities.firstIndex(where: { $0.id == editorID }),
            model.entities[index].components[EditorBuiltInComponentType.transform] != payload
        else {
            return
        }
        model.entities[index].components[EditorBuiltInComponentType.transform] = payload
        sceneModel = model
        syncRuntimeTransform(editorID: editorID, payload: payload)
        onTransformChanged?(editorID, payload)
        scheduleTransformInspectorUpdate(editorID: editorID)
    }

    private func scheduleTransformInspectorUpdate(editorID: String) {
        cancelTransformInspectorUpdate()
        transformInspectorUpdateTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard
                !Task.isCancelled, let self, self.selectedEditorID == editorID,
                let model = self.sceneModel
            else {
                return
            }
            self.transformInspectorUpdateTask = nil
            self.onSelectionChanged?(self.selectedEntityViewModel(editorID: editorID, model: model))
        }
    }

    private func cancelTransformInspectorUpdate() {
        transformInspectorUpdateTask?.cancel()
        transformInspectorUpdateTask = nil
    }

    func endTransformDrag(cancelled: Bool = false) {
        let drag = transformDrag
        transformDrag = nil
        hoveredGizmoHandle = nil
        guard let drag else {
            return
        }
        if cancelled {
            suppressSelectionOnPointerEnd = true
            applyTransformPayload(drag.startPayload, editorID: drag.editorID)
            cancelTransformInspectorUpdate()
            sceneContent = drag.startContent
            if let model = sceneModel {
                onSelectionChanged?(selectedEntityViewModel(editorID: drag.editorID, model: model))
            }
        } else if let model = sceneModel,
            let entity = model.entities.first(where: { $0.id == drag.editorID }),
            entity.components[EditorBuiltInComponentType.transform] != drag.startPayload,
            let content = try? model.encodedYAML() {
            // Commit once on release so Save and Undo see the latest transform immediately.
            sceneContent = content
            onDocumentContentChanged?(content)
        }
    }

    func syncRuntimeTransform(editorID: String, payload: EditorComponentPayload) {
        guard
            let runtimeID = entitiesByEditorID[editorID],
            let entity = world?.getEntityByID(runtimeID),
            let transform = try? EditorComponentPayloadDecoder.decode(Transform.self, payload: payload) as? Transform
        else {
            return
        }
        entity.components += transform
    }

    func vector(_ value: EditorSceneValue?, count: Int, defaultValues: [Double]) -> [Double] {
        guard case let .array(values)? = value else {
            return Array(defaultValues.prefix(count))
        }
        var result = values.map { $0.doubleValue ?? 0 }
        if result.count < count {
            result.append(contentsOf: defaultValues.dropFirst(result.count).prefix(count - result.count))
        }
        return Array(result.prefix(count))
    }

    func handleScroll(_ event: MouseEvent) -> Bool {
        switch displayMode {
        case .twoD:
            if event.modifierKeys.contains(.main) || event.modifierKeys.contains(.control) {
                zoom2D(by: event.scrollDelta.y)
            } else {
                pan2D(byScreenDelta: Vector2(event.scrollDelta.x, event.scrollDelta.y) * 72)
            }
        case .threeD:
            let speedMultiplier: Float = event.modifierKeys.contains(.shift) ? 4 : 1
            threeDPosition += front3D * event.scrollDelta.y * speedMultiplier
            applyCamera()
        }

        return true
    }

    func handleTouchEvent(_ event: TouchEvent) -> Bool {
        guard lastPinchScale == nil else {
            return true
        }
        switch event.phase {
        case .began:
            suppressSelectionOnPointerEnd = false
            touchDownPosition = event.location
            lastTouchPosition = event.location
            _ = beginTransformDragIfNeeded(at: event.location, button: .left)
            return true
        case .moved:
            if updateTransformDrag(to: event.location) {
                return true
            }
            guard let lastTouchPosition else {
                return false
            }

            let delta = event.location - lastTouchPosition
            switch displayMode {
            case .twoD:
                pan2D(byScreenDelta: delta)
            case .threeD:
                rotate3D(by: delta)
            }
            self.lastTouchPosition = event.location
            return true
        case .ended,
            .cancelled:
            if transformDrag != nil {
                if event.phase == .ended {
                    _ = updateTransformDrag(to: event.location)
                }
                endTransformDrag(cancelled: event.phase == .cancelled)
            } else if !suppressSelectionOnPointerEnd, event.phase == .ended, let touchDownPosition, (event.location - touchDownPosition).squaredLength < 16 {
                onSelectEntity?(displayMode == .twoD ? pick2D(at: event.location) : pick3D(at: event.location))
            }
            lastTouchPosition = nil
            touchDownPosition = nil
            suppressSelectionOnPointerEnd = false
            return true
        }
    }

    func handlePinchEvent(_ event: PinchEvent) -> Bool {
        guard event.scale.isFinite, event.scale > 0 else {
            return false
        }
        if event.phase == .began {
            endTransformDrag(cancelled: true)
            lastTouchPosition = nil
            touchDownPosition = nil
            suppressSelectionOnPointerEnd = true
            lastPinchScale = 1
        }
        guard let previousScale = lastPinchScale else {
            return false
        }
        if event.phase != .cancelled {
            let factor = event.scale / previousScale
            switch displayMode {
            case .twoD:
                let offset = Vector2(event.location.x - viewportSize.width * 0.5, viewportSize.height * 0.5 - event.location.y)
                let worldAnchor = twoDCenter + offset / twoDZoom
                twoDZoom = min(Self.maximumTwoDZoom, max(0.08, twoDZoom * factor))
                twoDCenter = worldAnchor - offset / twoDZoom
            case .threeD:
                threeDPosition += front3D * ((factor - 1) * 10)
            }
            applyCamera()
        }
        lastPinchScale = event.phase == .ended || event.phase == .cancelled ? nil : event.scale
        return true
    }

    func pan2D(byScreenDelta delta: Vector2) {
        twoDCenter.x -= delta.x / twoDZoom
        twoDCenter.y += delta.y / twoDZoom
        applyCamera()
    }

    func zoom2D(by delta: Float) {
        let factor = pow(Float(1.12), delta)
        twoDZoom = min(Self.maximumTwoDZoom, max(0.08, twoDZoom * factor))
        applyCamera()
    }

    func rotate3D(by delta: Vector2) {
        threeDYaw += delta.x * 0.008
        threeDPitch = min(1.45, max(-1.45, threeDPitch - delta.y * 0.008))
        applyCamera()
    }

    func advancePerspectiveTransition(deltaTime: Float) -> Bool {
        let target: Float = displayMode == .threeD ? 1 : 0
        guard perspectiveBlend != target else {
            return false
        }

        let step = max(0, deltaTime) / 0.5
        if target > perspectiveBlend {
            perspectiveBlend = min(target, perspectiveBlend + step)
        } else {
            perspectiveBlend = max(target, perspectiveBlend - step)
        }
        return true
    }

    var smoothPerspectiveBlend: Float {
        let value = min(max(perspectiveBlend, 0), 1)
        return value * value * (3 - 2 * value)
    }

    func movementVector() -> Vector3 {
        var movement = Vector3.zero
        let front = front3D
        let right = right3D

        if pressedKeys.contains(.w) {
            movement += front
        }
        if pressedKeys.contains(.s) {
            movement -= front
        }
        if pressedKeys.contains(.d) {
            movement += right
        }
        if pressedKeys.contains(.a) {
            movement -= right
        }
        if pressedKeys.contains(.e) {
            movement += .up
        }
        if pressedKeys.contains(.q) {
            movement -= .up
        }

        return movement
    }

    var front3D: Vector3 {
        Vector3(
            Math.sin(threeDYaw) * Math.cos(threeDPitch),
            Math.sin(threeDPitch),
            Math.cos(threeDYaw) * Math.cos(threeDPitch)
        )
        .normalized
    }

    var right3D: Vector3 {
        Vector3(Math.cos(threeDYaw), 0, -Math.sin(threeDYaw)).normalized
    }

    var up3D: Vector3 {
        front3D.cross(right3D).normalized
    }

    func applyCamera() {
        guard let cameraEntity = cameraEntity() else {
            return
        }

        guard
            var camera = cameraEntity.components[Camera.self],
            var transform = cameraEntity.components[Transform.self]
        else {
            return
        }

        let state = cameraState(for: viewportSize)
        camera.projection = state.projection
        transform = state.transform
        camera.backgroundColor = Color.fromHex(0x15181D)
        cameraEntity.components += CameraRenderGraph(
            subgraphLabel: state.renderGraphLabel,
            inputSlot: "view"
        )

        cameraEntity.components += camera
        cameraEntity.components += transform
        var environment = cameraEntity.components[Environment3D.self] ?? Environment3D()
        environment.skybox.isEnabled = smoothPerspectiveBlend > 0
        environment.screenSpaceReflection.isEnabled = smoothPerspectiveBlend > 0
        cameraEntity.components += environment
    }

    func cameraState(for size: Size) -> CameraState {
        let safeWidth = max(1, size.width)
        let safeHeight = max(1, size.height)
        var orthographic = OrthographicProjection(
            near: -10_000,
            far: 10_000,
            viewportOrigin: Vector2(0.5, 0.5),
            scale: twoDZoom
        )
        orthographic.updateView(width: safeWidth, height: safeHeight)
        var perspective = PerspectiveProjection(
            near: 0.1,
            far: 10_000,
            fieldOfView: .degrees(62),
            aspectRation: safeWidth / safeHeight
        )
        perspective.updateView(width: safeWidth, height: safeHeight)

        // Keep the orthographic editor camera behind the authored XY plane.
        // At z = 0 it sits inside meshes created at the default origin, so
        // their front faces are clipped or back-face culled in the 3D graph.
        let twoDTransform = Transform(position: Vector3(twoDCenter.x, twoDCenter.y, Self.twoDCameraDepth))
        let threeDTransform = Transform(
            matrix: Transform3D(columns: [
                Vector4(right3D, 0),
                Vector4(up3D, 0),
                Vector4(front3D, 0),
                Vector4(threeDPosition, 1),
            ])
        )
        let blend = smoothPerspectiveBlend

        let projection: Projection
        let transform: Transform
        if blend <= 0 {
            projection = .orthographic(orthographic)
            transform = twoDTransform
        } else if blend >= 1 {
            projection = .perspective(perspective)
            transform = threeDTransform
        } else {
            projection = .custom(
                EditorSceneViewportTransitionProjection(
                    matrix: interpolateMatrix(
                        from: orthographic.makeClipView(),
                        to: perspective.makeClipView(),
                        progress: blend
                    )
                )
            )
            transform = interpolateTransform(from: twoDTransform, to: threeDTransform, progress: blend)
        }

        return CameraState(
            projection: projection,
            transform: transform,
            renderGraphLabel: .main3D
        )
    }

    func interpolateMatrix(from start: Transform3D, to end: Transform3D, progress: Float) -> Transform3D {
        Transform3D(
            x: lerp(start.x, end.x, progress),
            y: lerp(start.y, end.y, progress),
            z: lerp(start.z, end.z, progress),
            w: lerp(start.w, end.w, progress)
        )
    }

    func interpolateTransform(from start: Transform, to end: Transform, progress: Float) -> Transform {
        var endRotation = end.rotation
        if start.rotation.dot(endRotation) < 0 {
            endRotation = Quat(x: -endRotation.x, y: -endRotation.y, z: -endRotation.z, w: -endRotation.w)
        }
        let rotation = Quat(
            x: start.rotation.x + (endRotation.x - start.rotation.x) * progress,
            y: start.rotation.y + (endRotation.y - start.rotation.y) * progress,
            z: start.rotation.z + (endRotation.z - start.rotation.z) * progress,
            w: start.rotation.w + (endRotation.w - start.rotation.w) * progress
        )
        .normalized
        return Transform(
            rotation: rotation,
            scale: lerp(start.scale, end.scale, progress),
            position: lerp(start.position, end.position, progress)
        )
    }

    func cameraEntity() -> Entity? {
        guard let world else {
            return nil
        }

        if let cameraEntityID, let entity = world.getEntityByID(cameraEntityID) {
            return entity
        }

        let entity = findCameraEntity(in: world)
        cameraEntityID = entity?.id
        return entity
    }

    func findCameraEntity(in world: World) -> Entity? {
        world.getEntities()
            .first { entity in
                entity.name == "SceneView_Camera"
                    && editorIDsByEntityID[entity.id] == nil
                    && entity.components[Camera.self] != nil
                    && entity.components[Transform.self] != nil
            }
    }
}

extension EditorSceneViewportModel {
    func pick2D(at screenPoint: Point) -> String? {
        guard let world else {
            return nil
        }

        let worldPoint = Vector2(
            twoDCenter.x + (screenPoint.x - viewportSize.width * 0.5) / twoDZoom,
            twoDCenter.y - (screenPoint.y - viewportSize.height * 0.5) / twoDZoom
        )

        return world.getEntities()
            .compactMap { entity -> (editorID: String, sortZ: Float)? in
                guard
                    entity.id != cameraEntityID,
                    let editorID = editorIDsByEntityID[entity.id],
                    let transform = entity.components[Transform.self]
                else {
                    return nil
                }

                let bounds = entity.components[BoundingComponent.self]
                guard EditorPicking.contains2D(worldPoint, transform: transform, bounds: bounds) else {
                    return nil
                }
                return (editorID, transform.position.z)
            }
            .max { lhs, rhs in lhs.sortZ < rhs.sortZ }?
            .editorID
    }

    func pick3D(at screenPoint: Point) -> String? {
        guard let world else {
            return nil
        }

        let ray = EditorPicking.perspectiveRay(
            point: screenPoint,
            viewportSize: viewportSize,
            cameraPosition: threeDPosition,
            front: front3D,
            right: right3D,
            verticalFieldOfView: .degrees(62)
        )

        return world.getEntities()
            .compactMap { entity -> (editorID: String, distance: Float)? in
                guard
                    entity.id != cameraEntityID,
                    let editorID = editorIDsByEntityID[entity.id],
                    let transform = entity.components[Transform.self]
                else {
                    return nil
                }

                let bounds = entity.components[BoundingComponent.self]
                guard let distance = EditorPicking.intersectionDistance(ray: ray, transform: transform, bounds: bounds) else {
                    return nil
                }
                return (editorID, distance)
            }
            .min { lhs, rhs in lhs.distance < rhs.distance }?
            .editorID
    }
}

extension EditorSceneViewportModel {
    private func selectEntity(_ editorID: String?) {
        cancelTransformInspectorUpdate()
        selectedEditorID = editorID
        guard var model = sceneModel else {
            onSelectionChanged?(nil)
            return
        }

        model.selectEntity(editorID)
        if let content = try? model.encodedYAML() {
            sceneContent = content
            sceneModel = model
            onDocumentContentChanged?(content)
        }
        onSelectionChanged?(selectedEntityViewModel(editorID: editorID, model: model))
    }

    private func selectedEntityViewModel(
        editorID: String?,
        model: EditorSceneModel
    ) -> EditorInspectorSidebarViewModel.SelectedEntity? {
        guard
            let editorID,
            let entity = model.entities.first(where: { $0.id == editorID })
        else {
            return nil
        }

        let transformFields = transformFields(from: entity)
        let componentNames = entity.components.keys
            .filter { $0 != EditorBuiltInComponentType.scriptableComponents }
            .sorted()
        let components = componentNames.map { componentSection(typeName: $0, payload: entity.components[$0] ?? [:]) }
        let addableComponents = EditorComponentRegistry.addableDescriptors(for: entity)
            .map {
                EditorInspectorSidebarViewModel.AddableComponent(
                    typeName: $0.typeName,
                    displayName: $0.displayName,
                    category: $0.category,
                    description: $0.description
                )
            }
        let gizmo = decodeGizmo(from: entity)
        let scriptableObjects = scriptableObjectSections(from: entity)
        let attachedScriptableIDs = Set(scriptableObjects.map(\.identifier))

        return EditorInspectorSidebarViewModel.SelectedEntity(
            editorID: entity.id,
            name: entity.name,
            componentNames: componentNames,
            transformFields: transformFields,
            components: components,
            addableComponents: addableComponents,
            scriptableObjects: scriptableObjects,
            addableScriptableObjects: scriptableObjectCatalog.filter { !attachedScriptableIDs.contains($0.identifier) },
            gizmo: gizmo,
            hasExplicitGizmo: entity.components[EditorSceneYAMLDocument.editorGizmoComponentName] != nil
        )
    }

    private func scriptableObjectSections(from entity: EditorSceneEntity) -> [EditorInspectorSidebarViewModel.ScriptableObjectSection] {
        guard case let .array(values)? = entity.components[EditorBuiltInComponentType.scriptableComponents]?["scripts"] else {
            return []
        }
        return values.compactMap { value in
            guard
                case let .object(object) = value,
                case let .string(identifier)? = object["type"]
            else {
                return nil
            }
            let descriptor = scriptableObjectCatalog.first { $0.identifier == identifier }
            let payload: EditorComponentPayload =
                if case let .object(payload)? = object["payload"] {
                    payload
                } else {
                    [:]
                }
            let fields: [EditorInspectorSidebarViewModel.ComponentField]
            if let descriptor {
                fields = descriptor.fields.map { field in
                    let editorField = EditorComponentField(key: field.name, label: field.name, kind: field.kind)
                    return EditorInspectorSidebarViewModel.ComponentField(
                        typeName: identifier,
                        field: editorField,
                        value: editorField.displayValue(in: payload)
                    )
                }
            } else {
                fields = [
                    EditorInspectorSidebarViewModel.ComponentField(
                        typeName: identifier,
                        field: EditorComponentField(key: "payload", label: "Payload", kind: .readOnly, isEditable: false),
                        value: EditorSceneValue.object(payload).stringValue
                    )
                ]
            }
            return EditorInspectorSidebarViewModel.ScriptableObjectSection(
                identifier: identifier,
                displayName: descriptor?.name ?? identifier,
                fields: fields
            )
        }
    }

    private func componentSection(typeName: String, payload: EditorComponentPayload) -> EditorInspectorSidebarViewModel.ComponentSection {
        let payload =
            [EditorBuiltInComponentType.physicsBody2D, EditorBuiltInComponentType.physicsBody3D].contains(typeName)
            ? EditorComponentRegistry.resolvedPhysicsPayload(payload, is3D: typeName == EditorBuiltInComponentType.physicsBody3D) : payload
        guard let descriptor = EditorComponentRegistry.descriptor(named: typeName) else {
            return EditorInspectorSidebarViewModel.ComponentSection(
                typeName: typeName,
                displayName: shortComponentName(typeName),
                fields: [
                    EditorInspectorSidebarViewModel.ComponentField(
                        typeName: typeName,
                        field: EditorComponentField(key: "payload", label: "Payload", kind: .readOnly, isEditable: false),
                        value: payload.description
                    )
                ],
                canRemove: typeName != EditorBuiltInComponentType.transform
            )
        }

        return EditorInspectorSidebarViewModel.ComponentSection(
            typeName: typeName,
            displayName: descriptor.displayName,
            fields: descriptor.fields.map {
                EditorInspectorSidebarViewModel.ComponentField(
                    typeName: typeName,
                    field: $0,
                    value: $0.displayValue(in: payload)
                )
            },
            canRemove: typeName != EditorBuiltInComponentType.transform
        )
    }

    private func transformFields(from entity: EditorSceneEntity) -> [EditorInspectorSidebarViewModel.TransformField] {
        guard
            let payload = entity.components[EditorBuiltInComponentType.transform],
            let descriptor = EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.transform)
        else {
            return []
        }

        return descriptor.fields.map {
            EditorInspectorSidebarViewModel.TransformField(field: $0, value: $0.displayValue(in: payload))
        }
    }

    private func decodeGizmo(from entity: EditorSceneEntity) -> EditorGizmo? {
        guard let payload = entity.components[EditorSceneYAMLDocument.editorGizmoComponentName] else {
            return nil
        }
        return try? EditorComponentPayloadDecoder.decode(EditorGizmo.self, payload: payload) as? EditorGizmo
    }

    private func projectedPoint(from transformPayload: EditorComponentPayload, size: Size) -> Point? {
        guard case let .array(position)? = transformPayload["position"], position.count >= 2 else {
            return nil
        }

        let world = Vector2(Float(position[0].doubleValue ?? 0), Float(position[1].doubleValue ?? 0))
        let z = position.count > 2 ? Float(position[2].doubleValue ?? 0) : 0
        return projectedPoint(from: Vector3(world.x, world.y, z), size: size)
    }

    private func projectedPoint(from position: Vector3, size: Size) -> Point? {
        project(position, size: size)
    }

    private func shortComponentName(_ componentName: String) -> String {
        componentName.components(separatedBy: ".").last ?? componentName
    }
}
