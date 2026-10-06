import AdaECS
@_spi(Internal) @testable import AdaInput
@_spi(Internal) @testable import AdaRender
@testable import AdaSprite
import AdaTransform
import AdaUtils
import Math
import Testing

@Suite("Sprite pointer routing")
@MainActor
struct SpritePointerTests {
    @Test("Press and release in the same frame produce one click before input cleanup")
    func clickInOneFrame() async throws {
        let fixture = makeFixture()
        let events = try await frame(fixture, [mouse(fixture.window, .began), mouse(fixture.window, .ended)])
        #expect(events.filter { $0.kind == .down }.map(\.entityID) == [fixture.sprite.id])
        #expect(events.filter { $0.kind == .click }.count == 1)
        #expect(fixture.world.getResource(Input.self)?.getInputEvents().isEmpty == true)
    }

    @Test("Dragging stays captured outside bounds and never becomes a click")
    func dragCapture() async throws {
        let fixture = makeFixture()
        _ = try await frame(fixture, [mouse(fixture.window, .began)])
        let drag = try await frame(fixture, [mouse(fixture.window, .changed, position: [90, 90])])
        #expect(drag.contains { $0.kind == .dragStart && $0.entityID == fixture.sprite.id })
        let moved = try #require(drag.first { $0.kind == .drag })
        #expect(moved.hit == nil)
        #expect(moved.delta == Vector2(40, 40))
        let end = try await frame(fixture, [mouse(fixture.window, .ended, position: [90, 90])])
        #expect(end.contains { $0.kind == .dragEnd })
        #expect(!end.contains { $0.kind == .click })
    }

    @Test("Hidden or removed targets cancel before a release can reach them")
    func removedCapture() async throws {
        let fixture = makeFixture()
        _ = try await frame(fixture, [mouse(fixture.window, .began)])
        fixture.world.removeEntity(fixture.sprite.id)
        let events = try await frame(fixture, [mouse(fixture.window, .ended)])
        #expect(events.contains { $0.kind == .cancel })
        #expect(!events.contains { $0.kind == .up || $0.kind == .click })
    }

    @Test("UI-consumed press cannot leak a click after the pointer leaves the UI")
    func blockedGesture() async throws {
        let fixture = makeFixture()
        let press = mouse(fixture.window, .began)
        let begin = try await frame(fixture, [press], blocked: [press.id])
        #expect(!begin.contains { $0.kind == .down })
        let end = try await frame(fixture, [mouse(fixture.window, .ended)])
        #expect(!end.contains { $0.kind == .click })
        let next = try await frame(fixture, [mouse(fixture.window, .began), mouse(fixture.window, .ended)])
        #expect(next.filter { $0.kind == .click }.count == 1)
    }

    @Test("Stationary hover follows moved sprites and per-frame UI blocking")
    func stationaryHover() async throws {
        let fixture = makeFixture()
        _ = try await frame(fixture, [mouse(fixture.window, .changed, button: .none)])
        #expect(fixture.world.getResource(SpritePickingState.self)?.hoveredEntities(for: .mouse(window: fixture.window)) == [fixture.sprite.id])
        fixture.sprite.components[Transform.self]?.position = [40, 40, 0]
        let moved = try await frame(fixture, [])
        #expect(moved.contains { $0.kind == .exit })
        fixture.sprite.components[Transform.self]?.position = .zero
        let returned = try await frame(fixture, [])
        #expect(returned.contains { $0.kind == .enter })
        let blocked = try await frame(fixture, [], blockedPointers: [.mouse(window: fixture.window)])
        #expect(blocked.contains { $0.kind == .exit })
    }

    @Test("Touches keep independent contact identity through click and cancellation")
    func touchIdentity() async throws {
        let fixture = makeFixture()
        let first = RID()
        let second = RID()
        #expect(first != second)
        let begin = try await frame(fixture, [
            TouchEvent(window: fixture.window, location: [50, 50], phase: .began, time: 0, contactID: first),
            TouchEvent(window: fixture.window, location: [50, 50], phase: .began, time: 0, contactID: second)
        ])
        #expect(begin.filter { $0.kind == .down }.count == 2)
        #expect(Set(begin.filter { $0.kind == .down }.map(\.pointer)).count == 2, "Begin: \(begin.map { String(describing: $0.pointer) })")
        #expect(fixture.world.getResource(SpritePickingState.self)?.pointers.count == 2)
        let end = try await frame(fixture, [
            TouchEvent(window: fixture.window, location: [50, 50], phase: .ended, time: 1, contactID: first),
            TouchEvent(window: fixture.window, location: [50, 50], phase: .cancelled, time: 1, contactID: second)
        ])
        #expect(end.contains { $0.kind == .click && $0.pointer == .touch(window: fixture.window, contact: first) })
        #expect(end.contains { $0.kind == .cancel && $0.pointer == .touch(window: fixture.window, contact: second) })
        #expect(fixture.world.getResource(Input.self)?.pointerLocations.isEmpty == true)
    }

    @Test("Window isolation and camera visibility prevent unrelated hits")
    func windowAndVisibility() async throws {
        let fixture = makeFixture()
        let unrelated = try await frame(fixture, [mouse(RID(), .began), mouse(RID(), .ended)])
        #expect(!unrelated.contains { $0.kind == .down || $0.kind == .click })
        fixture.camera.components[VisibleEntities.self] = VisibleEntities()
        let invisible = try await frame(fixture, [mouse(fixture.window, .began), mouse(fixture.window, .ended)])
        #expect(!invisible.contains { $0.kind == .down || $0.kind == .click })
    }

    private struct Fixture {
        let world: World
        let window: RID
        let sprite: Entity
        let camera: Entity
    }

    private func makeFixture() -> Fixture {
        Sprite.registerComponent()
        SpritePickable.registerComponent()
        SpritePickingView.registerComponent()
        Camera.registerComponent()
        VisibleEntities.registerComponent()
        Visibility.registerComponent()
        BoundingComponent.registerComponent()
        Transform.registerComponent()
        GlobalTransform.registerComponent()
        let world = World()
        world.insertResource(HandledEvents())
        world.insertResource(Input(gameControllerEngine: nil))
        world.insertResource(SpritePickingSettings())
        world.insertResource(SpritePickingState())
        world.addSystem(InputEventParseSystem.self, on: .preUpdate)
        world.addSystem(TransformSystem.self, on: .postUpdate)
        world.addSystem(ChildTransformSystem.self, on: .postUpdate)
        // Register cleanup first: the explicit before dependency must still preserve picking input.
        world.addSystem(InputEventsCleanupSystem.self, on: .postUpdate)
        world.addSystem(SpritePickingSystem.self, on: .postUpdate)
        let sprite = world.spawn {
            Sprite(size: Size(width: 20, height: 20))
            SpritePickable()
            Transform()
        }
        let window = RID()
        var camera = Camera(window: .windowId(window))
        camera.logicalViewport = Viewport(rect: Rect(x: 0, y: 0, width: 100, height: 100))
        camera.computedData.projectionMatrix = Transform3D.orthographic(left: -50, right: 50, top: 50, bottom: -50, zNear: 0, zFar: 100)
        camera.viewMatrix = Transform3D(translation: [0, 0, 10])
        let cameraEntity = world.spawn { camera; VisibleEntities(entityIds: [sprite.id]) }
        return Fixture(world: world, window: window, sprite: sprite, camera: cameraEntity)
    }

    private func frame(
        _ fixture: Fixture,
        _ pending: [any InputEvent],
        blocked: Set<RID> = [],
        blockedPointers: Set<InputPointerID> = []
    ) async throws -> [SpritePointerEvent] {
        if fixture.world.getResource(EventsStorage<SpritePointerEvent>.self) != nil {
            fixture.world.getRefResource(EventsStorage<SpritePointerEvent>.self).wrappedValue.swapAndDropOld()
        }
        fixture.world.getRefResource(Input.self).pendingEventsPool = pending
        await fixture.world.runScheduler(.preUpdate)
        for event in pending where blocked.contains(event.id) {
            fixture.world.getRefResource(Input.self).wrappedValue.blockScenePicking(for: event)
        }
        for pointer in blockedPointers {
            fixture.world.getRefResource(Input.self).wrappedValue.blockScenePicking(for: pointer)
        }
        await fixture.world.runScheduler(.postUpdate)
        let receiver = Events<SpritePointerEvent>()
        receiver.update(from: fixture.world)
        return Array(receiver.currentEvents)
    }

    private func mouse(_ window: RID, _ phase: MouseEvent.Phase, position: Point = [50, 50], button: MouseButton = .left) -> MouseEvent {
        MouseEvent(window: window, button: button, mousePosition: position, phase: phase, modifierKeys: [], time: 0)
    }
}
