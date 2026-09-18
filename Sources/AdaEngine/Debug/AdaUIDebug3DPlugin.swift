import AdaApp
import AdaAssets
import AdaCorePipelines
import AdaECS
import AdaInput
@_spi(Internal) import AdaRender
import AdaSprite
import AdaTransform
import AdaUI
import AdaUtils
import Math

/// Opens a separate AdaUI debug window that visualizes live AdaUI trees as spaced 2.5D layers.
public struct AdaUIDebug3DPlugin: Plugin {
    public enum Presentation: Sendable {
        case separateWindow
        case primaryWindowOverlay
        case separateWindowAndOverlay
    }

    private let title: String
    private let size: Size
    private let presentation: Presentation
    private let isEnabled: Bool

    public init(
        title: String = "AdaUI 3D Debug View",
        size: Size = Size(width: 1280, height: 820),
        presentation: Presentation = .separateWindow,
        isEnabled: Bool = false
    ) {
        self.title = title
        self.size = size
        self.presentation = presentation
        self.isEnabled = isEnabled
    }

    @MainActor
    public func setup(in app: borrowing AppWorlds) {
        let model = AdaUIDebug3DModel()
        if app.getResource(AdaUIDebug3DVisibility.self) == nil {
            app.insertResource(AdaUIDebug3DVisibility(isEnabled: isEnabled))
        }
        app
            .insertResource(AdaUIDebug3DResource(title: title, size: size, presentation: presentation, model: model))
            .addSystem(StartupAdaUIDebug3DSystem.self, on: .startup)
            .addSystem(UpdateAdaUIDebug3DSystem.self, on: .postUpdate)
    }

    @MainActor
    public func finish(for app: borrowing AppWorlds) {
        guard let debug = app.getResource(AdaUIDebug3DResource.self) else {
            return
        }

        let visibility = app.getResource(AdaUIDebug3DVisibility.self)
        debug.updateSurfaces(isEnabled: visibility?.isEnabled ?? false)
        debug.synchronizeOverlayFrame()
        debug.window?.setNeedsLayout()
        debug.window?.setNeedsDisplay()
        debug.overlayView?.setNeedsLayout()
        debug.overlayView?.setNeedsDisplay()
    }
}

public final class AdaUIDebug3DVisibility: Resource, @unchecked Sendable {
    @MainActor public var isEnabled: Bool

    @MainActor
    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }
}

public final class AdaUIDebug3DResource: Resource, @unchecked Sendable {
    @MainActor let title: String
    @MainActor let size: Size
    @MainActor let presentation: AdaUIDebug3DPlugin.Presentation
    @MainActor let model: AdaUIDebug3DModel
    @MainActor weak var window: UIWindow?
    @MainActor weak var overlayView: UIView?
    @MainActor private var didCreateWindow = false
    @MainActor private var didCreateOverlay = false
    @MainActor private var refreshAccumulator: TimeInterval = 0
    @MainActor private let autoRefreshInterval: TimeInterval = 0.35

    @MainActor
    init(
        title: String,
        size: Size,
        presentation: AdaUIDebug3DPlugin.Presentation,
        model: AdaUIDebug3DModel
    ) {
        self.title = title
        self.size = size
        self.presentation = presentation
        self.model = model
    }

    @MainActor
    func updateSurfaces(isEnabled: Bool) {
        guard isEnabled else {
            removeSurfaces()
            return
        }

        ensureSurfaces()
    }

    @MainActor
    func ensureSurfaces() {
        switch presentation {
        case .separateWindow:
            ensureWindow()
        case .primaryWindowOverlay:
            ensurePrimaryWindowOverlay()
        case .separateWindowAndOverlay:
            ensureWindow()
            ensurePrimaryWindowOverlay()
        }
    }

    @MainActor
    func removeSurfaces() {
        model.releaseScene()
        model.clearSnapshots()

        if let overlayView {
            model.ignoredContainerIds.remove(ObjectIdentifier(overlayView))
            overlayView.removeFromParentView()
            self.overlayView = nil
        }
        didCreateOverlay = false

        if let window {
            if model.debugWindowId == window.id {
                model.debugWindowId = nil
            }
            window.close()
            self.window = nil
        }
        didCreateWindow = false
        refreshAccumulator = 0
    }

    @MainActor
    func synchronizeOverlayFrame() {
        guard
            let overlayView,
            let appWorlds = AppWorldsSession.current,
            let primaryWindow = appWorlds.getResource(PrimaryWindow.self)?.window
        else {
            return
        }

        let expectedFrame = Rect(origin: .zero, size: primaryWindow.frame.size)
        guard overlayView.frame != expectedFrame else {
            return
        }

        overlayView.frame = expectedFrame
        overlayView.setNeedsLayout()
        overlayView.setNeedsDisplay()
    }

    @MainActor
    func autoRefreshIfNeeded(deltaTime: TimeInterval) -> Bool {
        guard model.autoRefresh else {
            refreshAccumulator = 0
            return false
        }

        refreshAccumulator += deltaTime
        guard refreshAccumulator >= autoRefreshInterval else {
            return false
        }

        refreshAccumulator = 0
        model.refresh()
        return true
    }

    @MainActor
    func updateCamera(deltaTime: TimeInterval) -> Bool { model.updateCamera(deltaTime: deltaTime) }
    @MainActor
    func syncScene() { model.syncScene() }
    @MainActor
    private func ensureWindow() {
        guard !didCreateWindow, window == nil else {
            return
        }
        didCreateWindow = true

        let window = UIWindow(
            configuration: UIWindow.Configuration(
                title: title,
                frame: Rect(x: 80, y: 80, width: size.width, height: size.height),
                minimumSize: Size(width: 900, height: 580),
                mode: .windowed,
                background: .opaque(Color.fromHex(0x202327)),
                level: .floating,
                showsImmediately: false,
                makeKey: false
            )
        )
        model.debugWindowId = window.id

        let container = UIContainerView(rootView: AdaUIDebug3DView(model: model))
        container.frame = Rect(origin: .zero, size: size)
        container.autoresizingRules = [.flexibleWidth, .flexibleHeight]
        container.backgroundColor = Color.fromHex(0x202327)
        window.addSubview(container)
        window.showWindow(makeFocused: true)

        model.refresh()
        self.window = window
    }

    @MainActor
    private func ensurePrimaryWindowOverlay() {
        guard !didCreateOverlay, overlayView == nil else {
            return
        }
        guard
            let appWorlds = AppWorldsSession.current,
            let primaryWindow = appWorlds.getResource(PrimaryWindow.self)?.window
        else {
            return
        }

        didCreateOverlay = true

        let overlay = UIContainerView(rootView: AdaUIDebug3DView(model: model))
        overlay.frame = Rect(origin: .zero, size: primaryWindow.frame.size)
        overlay.autoresizingRules = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = Color.fromHex(0x202327)
        overlay.zIndex = Int.max
        primaryWindow.addSubview(overlay)
        model.ignoredContainerIds.insert(ObjectIdentifier(overlay))
        model.refresh()
        overlay.setNeedsLayout()
        overlay.setNeedsDisplay()
        self.overlayView = overlay
    }
}

@System
@MainActor
func StartupAdaUIDebug3D(_ resource: Res<AdaUIDebug3DResource>, _ visibility: Res<AdaUIDebug3DVisibility>) {
    let debug = resource.wrappedValue
    debug.updateSurfaces(isEnabled: visibility.isEnabled)
    debug.synchronizeOverlayFrame()
    debug.window?.setNeedsLayout()
    debug.window?.setNeedsDisplay()
    debug.overlayView?.setNeedsLayout()
    debug.overlayView?.setNeedsDisplay()
}

@System
@MainActor
func UpdateAdaUIDebug3D(
    _ resource: Res<AdaUIDebug3DResource>,
    _ visibility: Res<AdaUIDebug3DVisibility>,
    _ deltaTime: Res<DeltaTime>
) {
    let debug = resource.wrappedValue
    debug.updateSurfaces(isEnabled: visibility.isEnabled)
    guard visibility.isEnabled else {
        return
    }

    debug.synchronizeOverlayFrame()
    let cameraDidUpdate = debug.updateCamera(deltaTime: deltaTime.deltaTime)
    let didRefresh = debug.autoRefreshIfNeeded(deltaTime: deltaTime.deltaTime)
    debug.syncScene()

    guard cameraDidUpdate || didRefresh else {
        return
    }

    if didRefresh {
        debug.window?.setNeedsLayout()
        debug.overlayView?.setNeedsLayout()
    } else {
        debug.window?.setNeedsDisplay()
        debug.overlayView?.setNeedsDisplay()
    }
}

@MainActor
final class AdaUIDebug3DModel {
    var debugWindowId: UIWindow.ID?
    var ignoredContainerIds: Set<ObjectIdentifier> = []
    var autoRefresh = true
    var selectedRuntimeId: String?
    var zoom: Float = 0.44
    var layerSpacing: Float = 24
    var depthLimit: Int = 36
    var pan = Point(48, 72)
    var yaw: Float = -0.42
    var pitch: Float = 0.24
    private var currentYaw: Float = -0.42
    private var currentPitch: Float = 0.24

    private(set) var windows: [AdaUIDebug3DWindowSnapshot] = []
    private(set) var lastItems: [AdaUIDebug3DLayout.Item] = []
    private(set) var selectedNode: UINodeSnapshot?
    private(set) var selectedPath: [UINodeSummary] = []
    private var snapshotVersion = 0
    private var cachedProjectionKey: ProjectionCacheKey?
    private var cachedProjectedItems: [AdaUIDebug3DLayout.Item] = []
    private weak var sceneWorld: World?
    private var sceneEntityId: Entity.ID?
    private var sceneMaterial = CustomMaterial(AdaUIDebugVertexColorMaterial())
    private var sceneKey: ProjectionCacheKey?
    private var sceneRotation = Quat.identity
    private var viewportSize = Size(width: 1280, height: 820)

    var selectedDescriptionLines: [String] {
        guard let node = selectedNode else {
            return ["No view selected", "Click a layer in the scene."]
        }

        var lines = [
            "Type: \(shortType(node.viewType))",
            "Node: \(shortType(node.nodeType))",
            "Runtime: \(node.runtimeId)",
            "Accessibility: \(node.accessibilityIdentifier ?? "-")",
            "Frame: \(format(node.frame))",
            "Absolute: \(format(node.absoluteFrame))",
            "Focused: \(node.isFocused ? "yes" : "no")",
            "Focusable: \(node.canBecomeFocused ? "yes" : "no")",
            "Interactable: \(node.isInteractable ? "yes" : "no")",
        ]

        if let hidden = node.isHidden {
            lines.append("Hidden: \(hidden ? "yes" : "no")")
        }

        return lines
    }

    var selectedPathLines: [String] {
        selectedPath.map { summary in
            "\(shortType(summary.viewType))  \(summary.accessibilityIdentifier ?? summary.runtimeId)"
        }
    }

    func refresh() {
        guard let manager = UIWindowManager.shared else {
            windows = []
            selectedNode = nil
            selectedPath = []
            invalidateProjection()
            return
        }

        let nextWindows: [AdaUIDebug3DWindowSnapshot] = manager.windows.values.compactMap { element in
            let window = element.value
            guard window.id != debugWindowId else {
                return nil
            }

            let roots = window.uiInspectableContainers()
                .filter { container in
                    !ignoredContainerIds.contains(ObjectIdentifier(container))
                }
                .flatMap { container in
                    container.uiTreeRoots()
                }

            guard !roots.isEmpty else {
                return nil
            }

            return AdaUIDebug3DWindowSnapshot(
                id: window.id,
                title: window.title.isEmpty ? "Window \(window.id.id)" : window.title,
                frame: window.frame,
                roots: roots
            )
        }

        guard nextWindows != windows else {
            return
        }

        windows = nextWindows
        snapshotVersion += 1
        invalidateProjection()
        resolveSelectedNode()
    }

    func project(size: Size) -> [AdaUIDebug3DLayout.Item] {
        let projection = AdaUIDebug3DProjection(
            zoom: zoom,
            layerSpacing: layerSpacing,
            pan: pan,
            viewportSize: size,
            depthLimit: depthLimit
        )
        let key = ProjectionCacheKey(
            snapshotVersion: snapshotVersion,
            projection: projection,
            selectedRuntimeId: selectedRuntimeId
        )
        if cachedProjectionKey == key {
            lastItems = cachedProjectedItems
            return cachedProjectedItems
        }

        lastItems = AdaUIDebug3DLayout.project(
            windows: windows,
            projection: projection,
            selectedRuntimeId: selectedRuntimeId
        )
        cachedProjectionKey = key
        cachedProjectedItems = lastItems
        return lastItems
    }

    func attachSceneWorld(_ world: World) {
        if sceneWorld !== world {
            releaseScene()
        }
        sceneWorld = world
        configureSceneCamera(viewportSize: viewportSize)
        sceneKey = nil
        syncScene()
    }

    func setViewportSize(_ size: Size) {
        guard size.width > 0, size.height > 0, viewportSize != size else {
            return
        }
        viewportSize = size
        invalidateProjection()
    }
    func releaseScene() {
        if let world = sceneWorld, let sceneEntityId {
            world.removeEntity(sceneEntityId, recursively: true)
            world.flush()
        }
        sceneWorld = nil
        sceneEntityId = nil
        sceneKey = nil
    }
    func clearSnapshots() {
        windows.removeAll(keepingCapacity: false)
        lastItems.removeAll(keepingCapacity: false)
        cachedProjectedItems.removeAll(keepingCapacity: false)
        selectedNode = nil
        selectedPath.removeAll(keepingCapacity: false)
        selectedRuntimeId = nil
        cachedProjectionKey = nil
        snapshotVersion += 1
    }
    func select(at point: Point, viewportSize: Size) {
        let items = lastItems.isEmpty ? project(size: viewportSize) : lastItems
        guard let item = AdaUIDebug3DLayout.pick(point, in: items) else {
            return
        }

        selectedRuntimeId = item.runtimeId
        invalidateProjection()
        resolveSelectedNode()
        highlightSelectedNode()
    }

    func resetCamera() {
        zoom = 0.44
        layerSpacing = 24
        depthLimit = 36
        pan = Point(48, 72)
        yaw = -0.42
        pitch = 0.24
        currentYaw = yaw
        currentPitch = pitch
        applySceneTransform()
        invalidateProjection()
    }

    func zoomBy(_ delta: Float) {
        zoom = min(2.5, max(0.2, zoom + delta))
        invalidateProjection()
    }

    func layerSpacingBy(_ delta: Float) {
        layerSpacing = min(140, max(6, layerSpacing + delta))
        invalidateProjection()
    }

    func depthLimitBy(_ delta: Int) {
        depthLimit = min(240, max(1, depthLimit + delta))
        invalidateProjection()
    }

    func setPan(_ newPan: Point) {
        pan = newPan
        invalidateProjection()
    }

    func rotateBy(deltaX: Float, deltaY: Float) {
        yaw += deltaX * 0.008
        pitch = min(1.15, max(-1.15, pitch + deltaY * 0.008))
    }

    func updateCamera(deltaTime: TimeInterval) -> Bool {
        let difference = abs(yaw - currentYaw) + abs(pitch - currentPitch)
        guard difference > 0.0001 else {
            return false
        }

        let interpolation = min(1, max(0.08, Float(deltaTime) * 18))
        currentYaw = lerpf(currentYaw, yaw, interpolation)
        currentPitch = lerpf(currentPitch, pitch, interpolation)

        if abs(yaw - currentYaw) + abs(pitch - currentPitch) < 0.0001 {
            currentYaw = yaw
            currentPitch = pitch
        }

        applySceneTransform()
        return true
    }

    private func invalidateProjection() {
        cachedProjectionKey = nil
        sceneKey = nil
    }

    func syncScene() {
        _ = project(size: viewportSize)
        guard let cachedProjectionKey else {
            return
        }
        syncSceneIfNeeded(items: cachedProjectedItems, viewportSize: viewportSize, key: cachedProjectionKey)
    }
    private func syncSceneIfNeeded(items: [AdaUIDebug3DLayout.Item], viewportSize: Size, key: ProjectionCacheKey) {
        guard sceneKey != key else {
            return
        }
        sceneKey = key
        rebuildScene(items: items, viewportSize: viewportSize)
    }

    private func applySceneTransform() {
        guard
            let world = sceneWorld,
            let sceneEntityId,
            let entity = world.getEntityByID(sceneEntityId)
        else {
            return
        }

        let rotation = sceneRotationValue()
        guard rotation != sceneRotation else {
            return
        }
        sceneRotation = rotation
        entity.components += sceneTransform()
    }

    private func sceneTransform() -> Transform {
        Transform(rotation: sceneRotation)
    }

    private func sceneRotationValue() -> Quat {
        Quat.euler(Vector3(currentPitch, currentYaw, 0)).normalized
    }

    private func rebuildScene(items: [AdaUIDebug3DLayout.Item], viewportSize: Size) {
        guard
            let world = sceneWorld,
            let device = world.getResource(RenderDeviceHandler.self)
        else {
            return
        }

        configureSceneCamera(viewportSize: viewportSize)

        let worldScale = sceneWorldScale(viewportSize: viewportSize)
        let mesh = makeBatchedLayerMesh(items: items, viewportSize: viewportSize, worldScale: worldScale, renderDevice: device.renderDevice)
        sceneRotation = sceneRotationValue()

        if let sceneEntityId, let entity = world.getEntityByID(sceneEntityId) {
            entity.components += Mesh2D(mesh: mesh, materials: [sceneMaterial])
            entity.components += sceneTransform()
            entity.components += Visibility.visible
            entity.components += NoFrustumCulling()
            world.flush()
            return
        }

        let entity = world.spawn("AdaUI Debug Layers") {
            Mesh2D(mesh: mesh, materials: [sceneMaterial])
            sceneTransform()
            Visibility.visible
            NoFrustumCulling()
        }
        sceneEntityId = entity.id
        world.flush()
    }

    private func makeBatchedLayerMesh(
        items: [AdaUIDebug3DLayout.Item],
        viewportSize: Size,
        worldScale: Float,
        renderDevice: RenderDevice
    ) -> Mesh {
        var descriptor = MeshDescriptor(name: "AdaUI Debug Layers")
        descriptor.primitiveTopology = .triangleList

        var positions: [Vector3] = []
        var colors: [Color] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(items.count * 16)
        colors.reserveCapacity(items.count * 16)
        indices.reserveCapacity(items.count * 24)

        let sortedItems = items.sorted { lhs, rhs in
            if lhs.depth == rhs.depth {
                return lhs.rect.area > rhs.rect.area
            }
            return lhs.depth < rhs.depth
        }

        for item in sortedItems {
            let rect = item.rect
            guard rect.width > 0, rect.height > 0 else {
                continue
            }

            let depth = Float((sortedItems.last?.depth ?? 0) - item.depth)
            let depthOffset = depth * layerSpacing
            let x = (rect.midX - viewportSize.width * 0.5) * worldScale
            let y = (viewportSize.height * 0.5 - rect.midY) * worldScale
            let z = depthOffset * worldScale
            let color = layerColor(for: item)

            let halfWidth = max(0.5, rect.width * worldScale * 0.5)
            let halfHeight = max(0.5, rect.height * worldScale * 0.5)
            let thickness = min(max(1.8 * worldScale, min(halfWidth, halfHeight) * 0.025), 5.5 * worldScale)
            appendOutline(
                minX: x - halfWidth,
                maxX: x + halfWidth,
                minY: y - halfHeight,
                maxY: y + halfHeight,
                z: z,
                thickness: thickness,
                color: color,
                positions: &positions,
                colors: &colors,
                indices: &indices
            )
        }

        if positions.isEmpty {
            positions = [
                Vector3(-1, -1, 1),
                Vector3(1, -1, 1),
                Vector3(1, 1, 1),
                Vector3(-1, 1, 1),
            ]
            colors = Array(repeating: Color.clear, count: 4)
            indices = [0, 1, 2, 2, 3, 0]
        }

        descriptor.positions = MeshBuffer(positions)
        descriptor.colors = MeshBuffer(colors)
        descriptor.indicies = indices
        return Mesh.generate(from: [descriptor], renderDevice: renderDevice)
    }

    private func configureSceneCamera(viewportSize: Size) {
        guard let world = sceneWorld else {
            return
        }

        let safeWidth = max(1, viewportSize.width)
        let safeHeight = max(1, viewportSize.height)
        let distance = max(safeWidth, safeHeight) * max(1.0, 1.28 / max(0.2, zoom))

        for entity in world.getEntities() {
            guard
                var camera = entity.components[Camera.self],
                var transform = entity.components[Transform.self]
            else {
                continue
            }

            var projection = PerspectiveProjection(near: 0.1, far: 10_000, fieldOfView: .degrees(54), aspectRation: safeWidth / safeHeight)
            projection.updateView(width: safeWidth, height: safeHeight)
            camera.projection = .perspective(projection)
            camera.backgroundColor = Color.fromHex(0x171A1F)
            transform.position = Vector3(0, 0, -distance)
            transform.rotation = Quat.identity
            entity.components += camera
            entity.components += transform
            return
        }
    }

    private func sceneWorldScale(viewportSize: Size) -> Float {
        let safeWidth = max(1, viewportSize.width)
        let safeHeight = max(1, viewportSize.height)
        let distance = max(safeWidth, safeHeight) * max(1.0, 1.28 / max(0.2, zoom))
        let fieldOfView = Float(54.0 * .pi / 180.0)
        let focalLength = safeHeight / (2 * tan(fieldOfView * 0.5))
        return max(0.1, distance / max(1, focalLength))
    }

    private func resolveSelectedNode() {
        guard let selectedRuntimeId else {
            selectedNode = nil
            selectedPath = []
            return
        }

        for window in windows {
            for root in window.roots {
                if let path = root.path(toRuntimeId: selectedRuntimeId) {
                    selectedNode = path.last
                    selectedPath = path.map(\.summary)
                    return
                }
            }
        }

        selectedNode = nil
        selectedPath = []
    }

    private func highlightSelectedNode() {
        guard let selectedRuntimeId else {
            return
        }

        for window in UIWindowManager.shared.windows.values {
            let sourceWindow = window.value
            guard sourceWindow.id != debugWindowId else {
                continue
            }

            for container in sourceWindow.uiInspectableContainers() {
                let matches = container.uiFindNodes(matching: .runtimeID(selectedRuntimeId))
                guard !matches.isEmpty else {
                    continue
                }
                container.uiSetDebugOverlay(.hitTestTarget)
                _ = container.uiHitTest(at: matches[0].absoluteFrame.center)
                return
            }
        }
    }
}

private func appendOutline(
    minX: Float,
    maxX: Float,
    minY: Float,
    maxY: Float,
    z: Float,
    thickness: Float,
    color: Color,
    positions: inout [Vector3],
    colors: inout [Color],
    indices: inout [UInt32]
) {
    let edges = [
        (minX, maxX, minY, minY + thickness),
        (minX, maxX, maxY - thickness, maxY),
        (minX, minX + thickness, minY, maxY),
        (maxX - thickness, maxX, minY, maxY),
    ]
    for edge in edges {
        appendQuad(minX: edge.0, maxX: edge.1, minY: edge.2, maxY: edge.3, z: z, color: color, positions: &positions, colors: &colors, indices: &indices)
    }
}

private func appendQuad(
    minX: Float,
    maxX: Float,
    minY: Float,
    maxY: Float,
    z: Float,
    color: Color,
    positions: inout [Vector3],
    colors: inout [Color],
    indices: inout [UInt32]
) {
    guard maxX > minX, maxY > minY else {
        return
    }

    let vertexStart = UInt32(positions.count)
    positions.append(contentsOf: [
        Vector3(minX, minY, z),
        Vector3(maxX, minY, z),
        Vector3(maxX, maxY, z),
        Vector3(minX, maxY, z),
    ])
    colors.append(contentsOf: [color, color, color, color])
    indices.append(contentsOf: [
        vertexStart, vertexStart + 1, vertexStart + 2,
        vertexStart + 2, vertexStart + 3, vertexStart,
    ])
}

private func layerColor(for item: AdaUIDebug3DLayout.Item) -> Color {
    if item.isSelected {
        return Color.fromHex(0x5EA1FF).opacity(0.96)
    }

    let palette = [0x5ED3F3, 0x6EA8FE, 0x9D8CFF, 0xF4B860, 0x74D99F, 0xF17EA8]
    let base = Color.fromHex(palette[item.depth % palette.count])
    return base.opacity(item.isInteractable ? 0.78 : 0.48)
}

private struct ProjectionCacheKey: Hashable {
    let snapshotVersion: Int
    let projection: AdaUIDebug3DProjection
    let selectedRuntimeId: String?
}

struct AdaUIDebug3DWindowSnapshot: Hashable {
    let id: UIWindow.ID
    let title: String
    let frame: Rect
    let roots: [UINodeSnapshot]
}

struct AdaUIDebug3DProjection: Hashable {
    var zoom: Float
    var layerSpacing: Float
    var pan: Point
    var viewportSize: Size
    var depthLimit: Int
}

enum AdaUIDebug3DLayout {
    struct Item: Identifiable, Hashable {
        let id: String
        let windowId: UIWindow.ID
        let runtimeId: String
        let label: String
        let rect: Rect
        let sourceFrame: Rect
        let depth: Int
        let color: Color
        let isSelected: Bool
        let isInteractable: Bool
    }

    static func project(
        windows: [AdaUIDebug3DWindowSnapshot],
        projection: AdaUIDebug3DProjection,
        selectedRuntimeId: String? = nil
    ) -> [Item] {
        var items: [Item] = []
        var yOffset: Float = 0

        for window in windows {
            let windowOrigin = Point(projection.pan.x, projection.pan.y + yOffset)
            for root in window.roots {
                append(
                    node: root,
                    window: window,
                    depth: 0,
                    baseOrigin: windowOrigin,
                    projection: projection,
                    selectedRuntimeId: selectedRuntimeId,
                    items: &items
                )
            }

            let height = max(window.frame.height * projection.zoom + 160, 240)
            yOffset += height
        }

        return items.sorted { $0.depth < $1.depth }
    }

    static func pick(_ point: Point, in items: [Item]) -> Item? {
        items
            .filter { $0.rect.contains(point: point) }
            .min { lhs, rhs in
                if lhs.depth == rhs.depth {
                    return lhs.rect.area < rhs.rect.area
                }
                return lhs.depth > rhs.depth
            }
    }

    private static func append(
        node: UINodeSnapshot,
        window: AdaUIDebug3DWindowSnapshot,
        depth: Int,
        baseOrigin: Point,
        projection: AdaUIDebug3DProjection,
        selectedRuntimeId: String?,
        items: inout [Item]
    ) {
        guard depth <= projection.depthLimit else {
            return
        }

        let source = node.absoluteFrame
        if source.width > 0, source.height > 0 {
            let offset = Float(depth) * projection.layerSpacing
            let rect = Rect(
                x: baseOrigin.x + source.origin.x * projection.zoom + offset,
                y: baseOrigin.y + source.origin.y * projection.zoom - offset * 0.44,
                width: max(1, source.width * projection.zoom),
                height: max(1, source.height * projection.zoom)
            )

            let viewport = Rect(
                x: -320,
                y: -320,
                width: projection.viewportSize.width + 640,
                height: projection.viewportSize.height + 640
            )
            if rect.intersects(viewport) {
                items.append(
                    Item(
                        id: "\(window.id.id)-\(node.runtimeId)",
                        windowId: window.id,
                        runtimeId: node.runtimeId,
                        label: shortType(node.viewType),
                        rect: rect,
                        sourceFrame: source,
                        depth: depth,
                        color: color(for: node),
                        isSelected: node.runtimeId == selectedRuntimeId,
                        isInteractable: node.isInteractable
                    )
                )
            }
        }

        for child in node.children {
            append(
                node: child,
                window: window,
                depth: depth + 1,
                baseOrigin: baseOrigin,
                projection: projection,
                selectedRuntimeId: selectedRuntimeId,
                items: &items
            )
        }
    }

    private static func color(for node: UINodeSnapshot) -> Color {
        let hash = node.accessibilityIdentifier ?? node.viewType
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in hash.utf8 {
            value ^= UInt64(byte)
            value &*= 0x100_0000_01b3
        }
        let hue = Int(value & 0x00FF_FFFF)
        return Color.fromHex(hue)
    }
}

struct AdaUIDebug3DView: View {
    let model: AdaUIDebug3DModel
    @State private var revision = 0
    @State private var lastDragLocation: Point?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                toolbar
                viewport
            }
            .padding(12)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.fromHex(0x202327))

            inspector
                .frame(width: 360)
                .background(Color.fromHex(0x292D33))
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.fromHex(0x202327))
        .onInputEvent(KeyEvent.self) { event in
            handleKey(event)
        }
    }

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 10) {
            toolbarButton("Refresh") {
                model.refresh()
                revision += 1
            }

            toolbarButton(model.autoRefresh ? "Auto On" : "Auto Off") {
                model.autoRefresh.toggle()
                revision += 1
            }

            toolbarButton("Reset") {
                model.resetCamera()
                revision += 1
            }

            Text("Zoom \(format(model.zoom))")
                .font(.system(size: 14))
                .foregroundColor(Color.white.opacity(0.82))

            toolbarButton("-", minWidth: 38) {
                model.zoomBy(-0.1)
                revision += 1
            }

            toolbarButton("+", minWidth: 38) {
                model.zoomBy(0.1)
                revision += 1
            }

            Text("Layer \(Int(model.layerSpacing))")
                .font(.system(size: 14))
                .foregroundColor(Color.white.opacity(0.82))

            toolbarButton("-", minWidth: 38) {
                model.layerSpacingBy(-6)
                revision += 1
            }

            toolbarButton("+", minWidth: 38) {
                model.layerSpacingBy(6)
                revision += 1
            }

            Text("Depth \(model.depthLimit)")
                .font(.system(size: 14))
                .foregroundColor(Color.white.opacity(0.82))

            toolbarButton("-", minWidth: 38) {
                model.depthLimitBy(-8)
                revision += 1
            }

            toolbarButton("+", minWidth: 38) {
                model.depthLimitBy(8)
                revision += 1
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.fromHex(0x171A1F))
        .border(Color.white.opacity(0.08), lineWidth: 1)
        .frame(height: 64, alignment: .leading)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .zIndex(10)
    }

    private func toolbarButton(_ title: String, minWidth: Float = 72, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(Color.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minWidth: minWidth, minHeight: 36)
                .background(Color.fromHex(0x252A31))
                .border(Color.white.opacity(0.16), lineWidth: 1)
        }
    }

    private var viewport: some View {
        ZStack {
            SceneView(
                make: { app in
                    app.addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(CameraPlugin()).addPlugin(AssetsPlugin(filePath: #filePath))
                    app.addPlugin(VisibilityPlugin()).addPlugin(SpritePlugin()).addPlugin(Mesh2DPlugin()).addPlugin(Core2DPlugin()).addPlugin(UpscalePlugin())
                    model.attachSceneWorld(app.main)
                },
                updateContent: { _, _ in }
            )
            GeometryReader { proxy in
                viewportOverlay(size: proxy.size)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private func viewportOverlay(size: Size) -> some View {
        _ = revision
        model.setViewportSize(size)
        return Color.clear
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if let lastDragLocation {
                            model.rotateBy(
                                deltaX: value.location.x - lastDragLocation.x,
                                deltaY: value.location.y - lastDragLocation.y
                            )
                        }
                        lastDragLocation = value.location
                    }
                    .onEnded { value in
                        lastDragLocation = nil
                        if abs(value.translation.width) < 3, abs(value.translation.height) < 3 {
                            model.select(at: value.location, viewportSize: size)
                            revision += 1
                        }
                    }
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Component Tree")
                .font(.system(size: 18))
                .foregroundColor(.white)

            Text("\(model.windows.count) windows  \(model.lastItems.count) layers")
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.58))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.selectedDescriptionLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.82))
                }
            }
            .padding(10)
            .background(Color.fromHex(0x202327))

            Text("Path")
                .font(.system(size: 15))
                .foregroundColor(.white)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.selectedPathLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.72))
                    }
                }
            }

            Spacer()
        }
        .padding(14)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    }

    private func handleKey(_ event: KeyEvent) {
        guard event.status == .down else {
            return
        }

        switch event.keyCode {
        case .equals,
            .plus:
            model.zoomBy(0.1)
        case .minus:
            model.zoomBy(-0.1)
        default:
            return
        }
        revision += 1
    }
}

private struct AdaUIDebugVertexColorMaterial: CanvasMaterial {}

extension UINodeSnapshot {
    var summary: UINodeSummary {
        UINodeSummary(
            runtimeId: runtimeId,
            accessibilityIdentifier: accessibilityIdentifier,
            nodeType: nodeType,
            viewType: viewType,
            frame: frame,
            absoluteFrame: absoluteFrame,
            canBecomeFocused: canBecomeFocused,
            isFocused: isFocused,
            isHidden: isHidden,
            isInteractable: isInteractable
        )
    }

    func path(toRuntimeId runtimeId: String) -> [UINodeSnapshot]? {
        if self.runtimeId == runtimeId {
            return [self]
        }

        for child in children {
            if let path = child.path(toRuntimeId: runtimeId) {
                return [self] + path
            }
        }

        return nil
    }
}

extension Rect {
    var center: Point { Point(midX, midY) }
    var area: Float { width * height }
}
private func shortType(_ type: String) -> String {
    type.split(separator: ".").last.map(String.init) ?? type
}
private func format(_ rect: Rect) -> String {
    "x:\(Int(rect.origin.x)) y:\(Int(rect.origin.y)) w:\(Int(rect.width)) h:\(Int(rect.height))"
}
private func format(_ value: Float) -> String {
    "\((value * 100).rounded() / 100)"
}
