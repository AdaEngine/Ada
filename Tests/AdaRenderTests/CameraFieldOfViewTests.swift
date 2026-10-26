import AdaRender
import Math
import Testing

@Suite("Perspective field of view")
struct CameraFieldOfViewTests {
    @Test func changingTheFieldOfViewUpdatesTheRealProjection() {
        var camera = Camera()
        camera.projection = .perspective(PerspectiveProjection())
        camera.projection.updateView(width: 128, height: 128)
        let before = camera.projection.makeClipView()
        camera.fieldOfViewDegrees = 90
        #expect(camera.fieldOfViewDegrees == 90)
        #expect(camera.projection.makeClipView() != before)
        #expect(abs(camera.projection.makeClipView().y.y - 1) < 0.00001)
        camera.fieldOfViewDegrees = .nan
        #expect(camera.fieldOfViewDegrees == 90)
        camera.fieldOfViewDegrees = 200
        #expect(camera.fieldOfViewDegrees == 179)
    }

    @Test func orthographicCamerasKeepTheirProjection() {
        var camera = Camera()
        camera.projection.updateView(width: 128, height: 128)
        let before = camera.projection.makeClipView()
        camera.fieldOfViewDegrees = 90
        #expect(camera.fieldOfViewDegrees == 0)
        #expect(camera.projection.makeClipView() == before)
    }
}
