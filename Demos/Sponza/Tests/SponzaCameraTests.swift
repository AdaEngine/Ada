import AdaTransform
import Testing
@testable import SponzaCamera

@Suite("Sponza fly camera")
struct SponzaCameraTests {
    @Test func yawTurnsHorizontallyAndPitchVerticallyWithoutRoll() {
        let yaw = Transform(rotation: SponzaFlyCamera.rotation(yaw: .pi / 2, pitch: 0)).matrix
        #expect(abs(yaw.z.x - 1) < 0.00001 && abs(yaw.z.y) < 0.00001 && abs(yaw.z.z) < 0.00001)
        let pitch = Transform(rotation: SponzaFlyCamera.rotation(yaw: 0, pitch: .pi / 4)).matrix
        #expect(pitch.z.y < -0.7 && pitch.z.z > 0.7 && abs(pitch.z.x) < 0.00001)
        let mixed = Transform(rotation: SponzaFlyCamera.rotation(yaw: 1.2, pitch: 0.6)).matrix
        #expect(abs(mixed.x.y) < 0.00001, "Camera right stays horizontal; there is no bank")
    }

    @Test func resetsPreservePoseAndMouseMotionDoesNotJumpAxes() {
        let pose = SponzaFlyCamera.looking(from: [-32, 25, -35], at: [0, 4, 0])
        var camera = SponzaFlyCamera()
        camera.setPose(pose)
        camera.look(delta: .zero)
        #expect(camera.transform == pose)
        camera.look(delta: [1, 0])
        #expect(abs(camera.transform.matrix.z.y - pose.matrix.z.y) < 0.00001)
        camera.look(delta: [0, 10000])
        #expect(camera.pitch <= 1.55)
    }

    @Test func movementHasConstantDiagonalSpeedAndUsesCameraForward() {
        var straight = SponzaFlyCamera(), diagonal = SponzaFlyCamera()
        straight.move(local: [0, 0, 1], seconds: 0.05, fast: false)
        diagonal.move(local: [1, 0, 1], seconds: 0.05, fast: false)
        #expect(abs(straight.transform.position.length - diagonal.transform.position.length) < 0.00001)
        var turned = SponzaFlyCamera()
        turned.setPose(Transform(rotation: SponzaFlyCamera.rotation(yaw: .pi / 2, pitch: 0)))
        turned.move(local: [0, 0, 1], seconds: 0.05, fast: false)
        #expect(abs(turned.transform.position.x - 0.15) < 0.00001 && abs(turned.transform.position.z) < 0.00001)
    }

    @Test func galleryMotionIsPeriodicAndKeepsTranslationInsideTheCorridor() {
        let origin = SponzaFlyCamera.looking(from: [-9.594356, 6.921101, 5.35278], at: [0, 6.921101, 5.35278])
        for mode in SponzaCameraMotion.allCases {
            #expect(mode.pose(from: origin, seconds: 0) == origin)
            #expect(mode.pose(from: origin, seconds: 6) == origin)
            #expect(mode.pose(from: origin, seconds: .nan) == origin)
        }
        let midpoint = SponzaCameraMotion.translation.pose(from: origin, seconds: 3)
        #expect(abs(midpoint.position.x - origin.position.x - 3) < 0.00001)
        #expect(midpoint.position.y == origin.position.y && midpoint.position.z == origin.position.z)
        #expect(midpoint.rotation == origin.rotation)
        let turned = SponzaCameraMotion.rotation.pose(from: origin, seconds: 1.5)
        #expect(turned.position == origin.position)
        #expect(abs(turned.matrix.x.y) < 0.00001)
        #expect(turned.rotation != origin.rotation)
    }

    @Test func flyingLightStaysInGalleryAndCompletesItsOrbit() {
        let start = SponzaLightMotion.position(seconds: 0)
        #expect((SponzaLightMotion.position(seconds: 12) - start).length < 0.0001)
        #expect(SponzaLightMotion.position(seconds: .nan) == start)
        #expect((SponzaLightMotion.position(seconds: 3) - start).length > 8)
        for step in 0...120 {
            let p = SponzaLightMotion.position(seconds: Double(step) / 10)
            #expect(abs(p.x) <= 8 && p.y >= 6.8 && p.y <= 8 && p.z >= 4.85 && p.z <= 5.85)
        }
    }
}
