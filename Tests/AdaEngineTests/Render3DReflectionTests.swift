#if os(macOS) || os(Windows) || os(Linux)
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

extension Render3DGPUTests {
    /// Screen-space reflections through the real pipeline. These frames guard performance work on the reflection
    /// pass: a faster trace must not visibly change what it draws.
    ///
    /// Run alone: `ADAENGINE_GOLDEN_SAGA=1 swift test --filter Render3DGPUTests/Reflections`.
    @Suite("3D reflections on GPU")
    @MainActor
    struct Reflections {
        /// A cheap early-out may differ from the full trace in faint reflections only.
        static let performanceTolerance = GoldenFrame.Tolerance(channelSteps: 3, differingFraction: 0.002)

        private static func expectGolden(_ image: Image, named name: String) throws {
            switch try GoldenFrame.check(image, name: name, tolerance: performanceTolerance) {
            case .recorded, .matched:
                break
            case .missingReference(let actual):
                Issue.record("No golden frame for \(name); record with ADAENGINE_GOLDEN_RECORD=1. Actual: \(actual.path)")
            case let .mismatched(comparison, actual, difference):
                Issue.record("\(name) differs in \(comparison.differingPixels) pixels (largest step \(comparison.largestStep)). Actual: \(actual.path), difference: \(difference.path)")
            }
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func reflectionsMatchTheirGoldenFrames() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            try scene.configure {
                $0.screenSpaceReflection.isEnabled = true
                $0.screenSpaceReflection.intensity = 1
            }
            let withReflections = try await scene.render(.none)
            try Self.expectGolden(withReflections, named: "pbr-spheres-ssr")
            try scene.configure { $0.skybox.isEnabled = true }
            try Self.expectGolden(try await scene.render(.none), named: "pbr-spheres-ssr-skybox")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func disablingReflectionsRemovesThemAndTheMetalSpheresKeepTheirLook() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            try scene.configure { $0.screenSpaceReflection.isEnabled = false }
            let off = try await scene.render(.none)
            try scene.configure { $0.screenSpaceReflection.isEnabled = true }
            let on = try await scene.render(.none)
            // The fully metallic sphere (rightmost) is where reflections matter; the matte ground must not change much.
            let sphere = (x: 490, y: 225), ground = (x: 320, y: 450)
            func luminance(_ image: Image, _ point: (x: Int, y: Int)) -> Float {
                let color = image.getPixel(x: point.x, y: point.y)
                return (color.red + color.green + color.blue) / 3
            }
            #expect(abs(luminance(on, ground) - luminance(off, ground)) * 255 <= 3, "Matte ground must not pick up visible reflections.")
            #expect(abs(luminance(on, sphere) - luminance(off, sphere)) * 255 > 0.5 || GoldenFrame.compare(on, off, tolerance: GoldenFrame.activeTolerance).differingPixels > 0, "Reflections must change something.")
        }
    }
}
#endif
