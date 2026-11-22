@testable import AdaCorePipelines
import Foundation
import Testing

@Suite("Path tracing intersection selection")
struct Render3DHardwareTraversalTests {
    @Test func automaticUsesHardwareWhenTheDeviceAndSceneAllowIt() {
        let selection = PathTracingTraversalSelection.select(.automatic, deviceSupportsRayQueries: true, sceneBlocker: nil)
        #expect(selection.traversal == .hardwareRayQuery && selection.fallbackReason == nil)
        #expect(selection.traversal.rawValue == "vulkan-ray-query")
    }

    @Test("Path tracing preserves the raster-first default for older settings and persists full primary rays")
    func rasterFirstHitSettings() throws {
        let legacy = try JSONDecoder().decode(PathTracing3D.self, from: Data("{\"isEnabled\":true}".utf8))
        #expect(legacy.rasterFirstHit)
        var fullRay = legacy
        fullRay.rasterFirstHit = false
        let encoded = try JSONEncoder().encode(fullRay)
        #expect(try JSONDecoder().decode(PathTracing3D.self, from: encoded).rasterFirstHit == false)
    }

    @Test func softwareIsAlwaysChosenWhenRequestedWithoutAReason() {
        let selection = PathTracingTraversalSelection.select(.software, deviceSupportsRayQueries: true, sceneBlocker: nil)
        #expect(selection.traversal == .softwareBVH && selection.fallbackReason == nil)
    }

    @Test func aDeviceWithoutRayQueriesFallsBackWithAReason() {
        let selection = PathTracingTraversalSelection.select(.automatic, deviceSupportsRayQueries: false, sceneBlocker: nil)
        #expect(selection.traversal == .softwareBVH)
        #expect((selection.fallbackReason ?? "").contains("ray quer"))
    }

    @Test func aSceneBlockerFallsBackAndNamesItself() {
        let selection = PathTracingTraversalSelection.select(
            .automatic, deviceSupportsRayQueries: true, sceneBlocker: "Skinned meshes are not supported by hardware ray queries"
        )
        #expect(selection.traversal == .softwareBVH)
        #expect(selection.fallbackReason == "Skinned meshes are not supported by hardware ray queries")
    }

    @Test func theDeviceReasonWinsWhenBothBlock() {
        let selection = PathTracingTraversalSelection.select(.automatic, deviceSupportsRayQueries: false, sceneBlocker: "skinned")
        #expect((selection.fallbackReason ?? "").contains("ray quer"))
    }

    @Test func intersectionDefaultsRoundTripsAndLegacyScenesDecodeUnchanged() throws {
        #expect(PathTracing3D().intersection == .automatic)
        var settings = PathTracing3D(isEnabled: true)
        settings.intersection = .software
        #expect(try JSONDecoder().decode(PathTracing3D.self, from: JSONEncoder().encode(settings)).intersection == .software)
        let legacy = try JSONDecoder().decode(PathTracing3D.self, from: Data("{\"isEnabled\":true}".utf8))
        #expect(legacy.intersection == .automatic)
    }

    @Test func statusStartsOnTheSoftwareTracerWithNoFallbackReason() {
        let status = PathTracing3DStatus()
        #expect(status.implementation == PathTracingTraversalSelection.Traversal.softwareBVH.rawValue)
        #expect(status.intersectionFallback == nil)
    }
}
