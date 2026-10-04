import AdaECS
import AdaSpatial
import AdaTransform
import Math
import Testing

@Suite("Spatial interactions", .serialized)
struct SpatialInteractionTests {
    @Test("A grab preserves its offset, follows the hand, and releases on tracking loss")
    func grabAndRelease() async throws {
        let fixture = Fixture()
        await fixture.frame([grip(.leftHand, [0.1, 0, 0])])
        #expect(fixture.selection.isGrabbed)
        await fixture.frame([grip(.leftHand, [0.4, 0.2, 0])])
        let transform = try #require(fixture.object.components[Transform.self])
        #expect((transform.position - Vector3(0.3, 0.2, 0)).length < 0.0001)
        await fixture.frame([])
        #expect(!fixture.selection.isGrabbed)
        #expect(fixture.selection.entityID == fixture.object.id)
        await fixture.frame([grip(.leftHand, [5, 0, 0])])
        #expect(fixture.object.components[Transform.self] == transform)
    }

    @Test("Two hands scale and rotate around their midpoint without jumps when a hand releases")
    func twoHands() async throws {
        let fixture = Fixture()
        await fixture.frame([grip(.leftHand, [-0.1, 0, 0])])
        await fixture.frame([grip(.leftHand, [-0.1, 0, 0]), grip(.rightHand, [0.1, 0, 0])])
        await fixture.frame([grip(.leftHand, [0, -0.2, 0]), grip(.rightHand, [0, 0.2, 0])])
        let transform = try #require(fixture.object.components[Transform.self])
        #expect(abs(transform.scale.x - 2) < 0.0001)
        let rotatedX = (Transform3D(quat: transform.rotation) * Vector4(1, 0, 0, 0)).xyz
        #expect((rotatedX - Vector3(0, 1, 0)).length < 0.0001)
        await fixture.frame([grip(.rightHand, [0, 0.2, 0])])
        #expect(fixture.object.components[Transform.self] == transform)
        await fixture.frame([grip(.rightHand, [0.2, 0.2, 0])])
        #expect(abs((fixture.object.components[Transform.self]?.position.x ?? 0) - 0.2) < 0.0001)
    }

    @Test("An indirect selection ray picks the nearest object and preserves hand offset")
    func distantRay() async throws {
        let fixture = Fixture()
        fixture.object.components[Transform.self] = Transform(position: [0, 0, 2])
        let other = fixture.world.spawn("Farther") {
            Transform(position: [0, 0, 4])
            SpatialGrabbable(halfExtents: [0.2, 0.2, 0.2])
        }
        let ray = Ray(origin: .zero, direction: [0, 0, 1])
        await fixture.frame([SpatialGrip(interactor: .pointer(1), pose: .identity, ray: ray)])
        #expect(fixture.selection.entityID == fixture.object.id)
        await fixture.frame([SpatialGrip(interactor: .pointer(1), pose: Transform3D(translation: [1, 0, 0]), ray: ray)])
        #expect(fixture.object.components[Transform.self]?.position == Vector3(1, 0, 2))
        #expect(other.components[Transform.self]?.position == Vector3(0, 0, 4))
    }

    @Test("An existing pinch in empty space does not acquire an object until released")
    func pinchMustBeginOnObject() async {
        let fixture = Fixture()
        await fixture.frame([grip(.leftHand, [5, 0, 0])])
        await fixture.frame([grip(.leftHand, [0, 0, 0])])
        #expect(!fixture.selection.isGrabbed)
        await fixture.frame([])
        await fixture.frame([grip(.leftHand, [0, 0, 0])])
        #expect(fixture.selection.isGrabbed)
        fixture.object.removeFromWorld()
        fixture.world.flush()
        await fixture.frame([grip(.leftHand, [0, 0, 0])])
        #expect(!fixture.selection.isGrabbed)
        #expect(fixture.selection.entityID == nil)
    }

    @Test("Reordered hands and unrelated pinches preserve the active grab")
    func interactorIdentity() async throws {
        let fixture = Fixture()
        await fixture.frame([grip(.leftHand, [-0.1, 0, 0])])
        await fixture.frame([grip(.leftHand, [-0.1, 0, 0]), grip(.rightHand, [5, 0, 0])])
        await fixture.frame([grip(.leftHand, [0.1, 0, 0]), grip(.rightHand, [5, 0, 0])])
        #expect(abs((fixture.object.components[Transform.self]?.position.x ?? 0) - 0.2) < 0.0001)
        await fixture.frame([])
        fixture.object.components[Transform.self] = Transform()
        await fixture.frame([grip(.leftHand, [-0.1, 0, 0])])
        await fixture.frame([grip(.rightHand, [0.1, 0, 0]), grip(.leftHand, [-0.1, 0, 0])])
        await fixture.frame([grip(.rightHand, [0.2, 0, 0]), grip(.leftHand, [-0.2, 0, 0])])
        #expect(abs((fixture.object.components[Transform.self]?.scale.x ?? 0) - 2) < 0.0001)
    }

    @Test("Invalid poses release and invalid rays never acquire objects")
    func invalidInput() async {
        let fixture = Fixture()
        await fixture.frame([grip(.leftHand, .zero)])
        var pose = Transform3D.identity
        pose[3, 0] = .nan
        await fixture.frame([SpatialGrip(interactor: .leftHand, pose: pose)])
        #expect(!fixture.selection.isGrabbed)
        #expect(fixture.object.components[Transform.self]?.position == .zero)
        await fixture.frame([SpatialGrip(interactor: .pointer(2), pose: .identity, ray: Ray(origin: .zero, direction: [.nan, 0, 1]))])
        #expect(!fixture.selection.isGrabbed)
    }

    @Test("Pinch thresholds have hysteresis and tracking loss releases immediately")
    func pinchHysteresis() {
        var pinch = SpatialPinchState()
        let before = pinch.update(distance: 0.03, isTracked: true)
        let began = pinch.update(distance: 0.02, isTracked: true)
        let held = pinch.update(distance: 0.03, isTracked: true)
        let lost = pinch.update(distance: nil, isTracked: false)
        let invalid = pinch.update(distance: .nan, isTracked: true)
        #expect(!before)
        #expect(began)
        #expect(held)
        #expect(!lost)
        #expect(!invalid)
    }

    @Test("Coordinate conversion preserves rotations and projections map near to zero")
    func coordinates() {
        let apple = Transform3D(translation: [1, 2, -3], rotation: Quat(axis: [0, 1, 0], angle: 0.5), scale: .one)
        let converted = SpatialCoordinates.fromApple(apple)
        #expect(converted.origin == Vector3(1, 2, 3))
        #expect(abs(converted.determinant - 1) < 0.0001)
        #expect(SpatialCoordinates.fromApple(converted) == apple)
        let forward = Transform3D.perspective(fieldOfView: .degrees(80), aspectRatio: 1, zNear: 0.1, zFar: 100)
        let reverse = SpatialCoordinates.forwardDepthProjection(forward)
        let restored = SpatialCoordinates.forwardDepthProjection(reverse)
        let near = restored * Vector4(0, 0, 0.1, 1)
        let far = restored * Vector4(0, 0, 100, 1)
        #expect(abs(near.z / near.w) < 0.0001)
        #expect(abs(far.z / far.w - 1) < 0.0001)
    }

    @Test("Native compositor projections accept Ada's positive-Z-forward camera space")
    func nativeProjectionHandedness() {
        let near: Float = 0.1
        let far: Float = 100
        let nativeReverseZ = Transform3D(rows: [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, near / (far - near), near * far / (far - near)],
            [0, 0, -1, 0],
        ])
        let projection = SpatialCoordinates.fromAppleProjection(nativeReverseZ)
        let nearClip = projection * Vector4(0, 0, near, 1)
        let farClip = projection * Vector4(0, 0, far, 1)
        let frontClip = projection * Vector4(0.2, 0.1, 1, 1)
        #expect(nearClip.w > 0)
        #expect(farClip.w > 0)
        #expect(frontClip.w > 0)
        #expect(abs(nearClip.z / nearClip.w) < 0.0001)
        #expect(abs(farClip.z / farClip.w - 1) < 0.0001)
        #expect(abs(frontClip.x / frontClip.w - 0.2) < 0.0001)
    }

    private func grip(_ interactor: SpatialInteractor, _ position: Vector3) -> SpatialGrip {
        SpatialGrip(interactor: interactor, pose: Transform3D(translation: position))
    }
}

private struct Fixture {
    let world = World()
    let object: Entity
    var selection: SpatialSelection { world.getResource(SpatialSelection.self) ?? SpatialSelection() }

    init() {
        object = world.spawn("Box") {
            Transform()
            SpatialGrabbable(halfExtents: [0.2, 0.2, 0.2])
        }
        world.insertResource(SpatialInput())
        world.insertResource(SpatialSelection())
        world.addSystem(SpatialInteractionSystem.self, on: .update)
    }

    func frame(_ grips: [SpatialGrip]) async {
        world.insertResource(SpatialInput(grips: grips))
        await world.runScheduler(.update)
    }
}
