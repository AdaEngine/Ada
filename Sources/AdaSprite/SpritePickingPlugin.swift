import AdaApp
import AdaECS
import AdaInput
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUtils
import Math

public struct SpritePickingSettings: Resource {
    public var isEnabled: Bool
    public var dragThreshold: Float
    /// Match the renderer's per-camera visible set. Tools may disable this for explicit snapshots.
    public var respectsCameraVisibility: Bool

    public init(isEnabled: Bool = true, dragThreshold: Float = 4, respectsCameraVisibility: Bool = true) {
        self.isEnabled = isEnabled
        self.dragThreshold = dragThreshold
        self.respectsCameraVisibility = respectsCameraVisibility
    }
}

/// Connects an offscreen/embedded camera to a window's pointer input. Window cameras need no marker.
@Component
public struct SpritePickingView: Sendable {
    public var window: WindowRef

    public init(window: WindowRef = .primary) {
        self.window = window
    }
}

/// Optional pointer interaction. Install alongside InputPlugin, SpritePlugin and EventsPlugin.
/// Add SpritePickable to interactive sprites; the plugin never mutates gameplay transforms.
public struct SpritePickingPlugin: Plugin {
    private let settings: SpritePickingSettings

    public init(settings: SpritePickingSettings = SpritePickingSettings()) {
        self.settings = settings
    }

    public func setup(in app: AppWorlds) {
        SpritePickable.registerComponent()
        SpritePickingView.registerComponent()
        app.insertResource(settings)
            .insertResource(SpritePickingState())
            .addSystem(SpritePickingSystem.self, on: .postUpdate)
    }
}

struct SpritePickingFrameCamera: Sendable {
    let camera: SpritePickingCamera
    let windowID: RID
    let visible: Set<Entity.ID>
}

@PlainSystem(dependencies: [
    .after(TransformSystem.self),
    .after(ChildTransformSystem.self),
    .before(InputEventsCleanupSystem.self)
])
public struct SpritePickingSystem {
    @Query<Entity, Sprite, SpritePickable, GlobalTransform, Visibility> private var sprites
    @Query<Entity, Camera, VisibleEntities> private var cameras
    @Query<Entity, SpritePickingView> private var cameraWindows
    @Res private var primaryWindow: PrimaryWindowId?
    @Res<Input> private var input
    @Res<SpritePickingSettings> private var settings
    @ResMut<SpritePickingState> private var state
    @EventsSender<SpritePointerEvent> private var events

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        var candidates: [SpritePickingCandidate] = []
        var views: [SpritePickingFrameCamera] = []
        if settings.isEnabled {
            sprites.forEach { entity, sprite, pickable, transform, visibility in
                guard entity.isActive, visibility != .hidden, pickable.isEnabled else {
                    return
                }
                candidates.append(SpritePickingCandidate(entityID: entity.id, sprite: sprite, worldTransform: transform.matrix, pickable: pickable))
            }
            var overrides: [Entity.ID: WindowRef] = [:]
            cameraWindows.forEach { entity, view in overrides[entity.id] = view.window }
            cameras.forEach { entity, camera, visible in
                guard entity.isActive, camera.isActive else {
                    return
                }
                let windowRef: WindowRef
                if let override = overrides[entity.id] {
                    windowRef = override
                } else if case let .window(window) = camera.renderTarget {
                    windowRef = window
                } else {
                    return
                }
                let windowID: RID
                switch windowRef {
                case .primary:
                    guard let primaryWindow else {
                        return
                    }
                    windowID = primaryWindow.windowId
                case let .windowId(id): windowID = id
                }
                views.append(SpritePickingFrameCamera(
                    camera: SpritePickingCamera(
                        entityID: entity.id,
                        viewport: camera.logicalViewport.rect,
                        projection: camera.computedData.projectionMatrix,
                        worldTransform: camera.viewMatrix.inverse,
                        renderOrder: camera.renderOrder
                    ),
                    windowID: windowID,
                    visible: visible.entityIds
                ))
            }
            views.sort {
                if $0.camera.renderOrder != $1.camera.renderOrder {
                    return $0.camera.renderOrder > $1.camera.renderOrder
                }
                return $0.camera.entityID > $1.camera.entityID
            }
        }
        let alive = Set(candidates.map(\.entityID))
        let activeCameras = Set(views.map { $0.camera.entityID })
        let dragThreshold = settings.dragThreshold.isFinite ? max(0.001, settings.dragThreshold) : 4
        for (pointer, position) in input.pointerLocations where state.pointers[pointer] == nil {
            state.pointers[pointer] = SpritePointerTracker(position: position)
        }
        // Cancel removed/hidden targets before processing a release in the same frame.
        for pointer in Array(state.pointers.keys) {
            guard var tracker = state.pointers[pointer] else {
                continue
            }
            for (button, captures) in tracker.captures {
                let kept = captures.filter { alive.contains($0.hit.entityID) && activeCameras.contains($0.hit.cameraID) }
                for capture in captures where !alive.contains(capture.hit.entityID) || !activeCameras.contains(capture.hit.cameraID) {
                    events.send(tracker.event(.cancel, pointer: pointer, target: capture.hit, button: button == .none ? nil : button, position: tracker.position))
                }
                tracker.captures[button] = kept.isEmpty ? nil : kept
            }
            state.pointers[pointer] = tracker
        }
        for event in input.getInputEvents() {
            let pointer: InputPointerID
            let position: Point
            let phase: MouseEvent.Phase
            let button: MouseButton?
            if let mouse = event as? MouseEvent, mouse.button != .scrollWheel {
                pointer = .mouse(window: mouse.window)
                position = mouse.mousePosition
                phase = mouse.phase
                button = mouse.button
            } else if let touch = event as? TouchEvent {
                pointer = .touch(window: touch.window, contact: touch.contactID)
                position = touch.location
                button = nil
                switch touch.phase {
                case .began: phase = .began
                case .moved: phase = .changed
                case .ended: phase = .ended
                case .cancelled: phase = .cancelled
                }
            } else {
                continue
            }
            guard position.x.isFinite, position.y.isFinite else {
                continue
            }
            var tracker = state.pointers[pointer] ?? SpritePointerTracker(position: position)
            let hits = pick(pointer: pointer, position: position, candidates: candidates, views: views)
            tracker.process(
                pointer: pointer,
                position: position,
                phase: phase,
                button: button,
                hits: hits,
                blocked: !settings.isEnabled || input.isScenePickingBlocked(eventID: event.id),
                dragThreshold: dragThreshold,
                emit: events.send
            )
            if case .touch = pointer, phase == .ended || phase == .cancelled {
                tracker.updateHover([], pointer: pointer, position: position, emit: events.send)
                state.pointers[pointer] = nil
            } else if phase == .cancelled {
                tracker.cancelCaptures(pointer: pointer, position: position, emit: events.send)
                tracker.updateHover([], pointer: pointer, position: position, emit: events.send)
                state.pointers[pointer] = nil
            } else {
                state.pointers[pointer] = tracker
            }
        }
        // Re-evaluate stationary pointers when sprites move or UI overlays appear.
        for pointer in Array(state.pointers.keys) {
            guard var tracker = state.pointers[pointer] else {
                continue
            }
            let blocked = !settings.isEnabled || input.isScenePickingBlocked(pointer: pointer)
            let hits = blocked ? [] : pick(pointer: pointer, position: tracker.position, candidates: candidates, views: views)
            tracker.updateHover(hits, pointer: pointer, position: tracker.position, emit: events.send)
            if blocked {
                tracker.cancelCaptures(pointer: pointer, position: tracker.position, emit: events.send)
            }
            state.pointers[pointer] = views.contains(where: { $0.windowID == pointer.windowID }) ? tracker : nil
        }
    }

    private func pick(
        pointer: InputPointerID,
        position: Point,
        candidates: [SpritePickingCandidate],
        views: [SpritePickingFrameCamera]
    ) -> [SpritePickHit] {
        for view in views where view.windowID == pointer.windowID {
            let filtered = settings.respectsCameraVisibility ? candidates.filter { view.visible.contains($0.entityID) } : candidates
            let hits = SpritePicker.pick(at: position, camera: view.camera, candidates: filtered)
            if !hits.isEmpty {
                return hits
            }
        }
        return []
    }
}
