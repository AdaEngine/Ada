import AdaCorePipelines
import Foundation
import Math
import Testing

@Suite("Local environment probe settings")
struct LocalEnvironmentProbe3DTests {
    let probe = LocalEnvironmentProbe3D(capturePosition: [0, 1, 0], minimum: [-4, 0, -4], maximum: [4, 4, 4])

    @Test func legacyEnvironmentAndProbeRoundTrip() throws {
        #expect(try JSONDecoder().decode(Environment3D.self, from: Data("{}".utf8)).localEnvironmentProbe == nil)
        var environment = Environment3D()
        environment.localEnvironmentProbe = probe
        #expect(try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment)).localEnvironmentProbe == probe)
    }

    @Test func parallelAxesAndCaptureCentreStayFinite() {
        #expect(probe.isValid)
        let direction = probe.projectedDirection(position: [0, 1, 0], direction: [1, 0, 0])
        #expect(direction == Vector3(1, 0, 0))
        let shifted = probe.projectedDirection(position: [0, 2, 0], direction: [1, 0, 0])
        #expect(abs(shifted.x - 4 / sqrt(17)) < 0.0001)
        #expect(abs(shifted.y - 1 / sqrt(17)) < 0.0001)
        #expect(shifted.z == 0)
    }

    @Test func outsideInvalidAndZeroRaysRetainTheInfiniteEnvironment() {
        let direction = Vector3(0, 0, 1)
        #expect(probe.projectedDirection(position: [8, 1, 0], direction: direction) == direction)
        #expect(probe.projectedDirection(position: [0, 1, 0], direction: .zero) == .zero)
        var invalid = probe
        invalid.minimum.x = .nan
        #expect(!invalid.isValid)
        #expect(invalid.projectedDirection(position: [0, 1, 0], direction: direction) == direction)
        invalid = probe
        invalid.maximum.y = invalid.minimum.y
        #expect(!invalid.isValid)
        invalid = probe
        invalid.capturePosition.x = 100
        #expect(!invalid.isValid)
    }

    @Test func negativeRaysExitThroughTheNearBoundary() {
        let direction = probe.projectedDirection(position: [1, 1, 0], direction: [-1, 0, -1])
        let expected = Vector3(-3, 0, -4).normalized
        #expect((direction - expected).length < 0.0001)
    }
}
