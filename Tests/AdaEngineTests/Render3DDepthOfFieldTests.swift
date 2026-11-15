#if os(macOS) || os(Windows) || os(Linux)
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

/// Depth of field settings that need no GPU.
@Suite("3D depth of field settings")
struct Render3DDepthOfFieldSettingsTests {
    @Test func defaultsAreOff() {
        let settings = DepthOfField3D()
        #expect(!settings.isEnabled && !settings.changesImage)
        #expect(PostProcess3D().depthOfField == settings)
    }

    @Test func olderPayloadsDecodeWithoutDepthOfField() throws {
        let decoded = try JSONDecoder().decode(PostProcess3D.self, from: Data(#"{"exposureEV":1}"#.utf8))
        #expect(decoded.depthOfField == DepthOfField3D())
        let partial = try JSONDecoder().decode(DepthOfField3D.self, from: Data(#"{"isEnabled":true,"focusDistance":12}"#.utf8))
        #expect(partial.isEnabled && partial.focusDistance == 12 && partial.aperture == DepthOfField3D().aperture)
    }

    @Test func settingsRoundTripAndFlatAccessors() throws {
        var environment = Environment3D()
        environment.depthOfFieldEnabled = true
        environment.focusDistance = 7
        environment.postProcess.depthOfField.aperture = 2.5
        let decoded = try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment))
        #expect(decoded.postProcess.depthOfField == environment.postProcess.depthOfField)
        #expect(decoded.depthOfFieldEnabled && decoded.focusDistance == 7)
    }

    @Test func wildValuesAreClamped() {
        let wild = DepthOfField3D(isEnabled: true, focusDistance: -3, aperture: .nan, maximumBlurRadius: 1000).sanitized
        #expect(wild.focusDistance == 0.05)
        #expect(wild.aperture == DepthOfField3D().aperture)
        #expect(wild.maximumBlurRadius == 32)
    }

    @Test func settingsThatCannotBlurAreNotCountedAsAnEffect() {
        #expect(!DepthOfField3D(isEnabled: false).changesImage)
        #expect(!DepthOfField3D(isEnabled: true, aperture: 0).changesImage)
        #expect(!DepthOfField3D(isEnabled: true, maximumBlurRadius: 0.2).changesImage)
        #expect(DepthOfField3D(isEnabled: true).changesImage)
    }

    @Test func laterPassesFlagCoversDebugViewsAndDepthOfField() {
        var environment = Environment3D()
        #expect(!environment.laterPassesWriteOutput)
        environment.debugView = .normals
        #expect(environment.laterPassesWriteOutput)
        environment.debugView = .wireframe
        #expect(!environment.laterPassesWriteOutput, "Wireframe draws in the main pass, so nothing writes later.")
        environment.postProcess.depthOfField.isEnabled = true
        #expect(environment.laterPassesWriteOutput)
    }
}

extension Render3DGPUTests {
    /// Renders depth of field through the real pipeline.
    ///
    /// Run alone: `ADAENGINE_GOLDEN_SAGA=1 swift test --filter Render3DGPUTests/DepthOfField`.
    @Suite("3D depth of field on GPU")
    @MainActor
    struct DepthOfField {
        private static func luminance(_ color: Color) -> Float { (color.red + color.green + color.blue) / 3 }

        /// Largest luminance step between neighbors along a row segment, as a measure of edge sharpness.
        private static func horizontalSharpness(_ image: Image, row: Int, columns: ClosedRange<Int>) -> Float {
            var largest: Float = 0
            for x in columns.lowerBound..<columns.upperBound {
                largest = max(largest, abs(luminance(image.getPixel(x: x + 1, y: row)) - luminance(image.getPixel(x: x, y: row))))
            }
            return largest
        }

        /// Largest luminance step between neighbors down a column segment.
        private static func verticalSharpness(_ image: Image, column: Int, rows: ClosedRange<Int>) -> Float {
            var largest: Float = 0
            for y in rows.lowerBound..<rows.upperBound {
                largest = max(largest, abs(luminance(image.getPixel(x: column, y: y + 1)) - luminance(image.getPixel(x: column, y: y))))
            }
            return largest
        }

        private static func expectGolden(_ image: Image, named name: String) throws {
            switch try GoldenFrame.check(image, name: name) {
            case .recorded, .matched:
                break
            case .missingReference(let actual):
                Issue.record("No golden frame for \(name); record with ADAENGINE_GOLDEN_RECORD=1. Actual: \(actual.path)")
            case let .mismatched(comparison, actual, difference):
                Issue.record("\(name) differs in \(comparison.differingPixels) pixels. Actual: \(actual.path), difference: \(difference.path)")
            }
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func disabledDepthOfFieldChangesNothingAndHoldsNoScratch() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            func views() throws -> DepthOfField3DViews { try #require(renderWorld.getResource(DepthOfField3DViews.self)) }
            let baseline = try await scene.render(.none)
            // Settings that cannot blur are ignored even when enabled.
            for settings in [
                DepthOfField3D(isEnabled: false, focusDistance: 1, aperture: 5, maximumBlurRadius: 20),
                DepthOfField3D(isEnabled: true, focusDistance: 1, aperture: 0, maximumBlurRadius: 20),
                DepthOfField3D(isEnabled: true, focusDistance: 1, aperture: 5, maximumBlurRadius: 0),
            ] {
                try scene.configure { $0.postProcess.depthOfField = settings }
                let image = try await scene.render(.none)
                #expect(GoldenFrame.compare(baseline, image, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
                #expect(try !views().hasScratch(view: scene.camera.id))
            }
            try scene.configure { $0.postProcess.depthOfField = DepthOfField3D(isEnabled: true, focusDistance: 3.4) }
            _ = try await scene.render(.none)
            #expect(try views().hasScratch(view: scene.camera.id))
            try scene.configure { $0.postProcess.depthOfField.isEnabled = false }
            let released = try await scene.render(.none)
            #expect(try !views().hasScratch(view: scene.camera.id), "Turning the effect off must release the scratch texture.")
            #expect(GoldenFrame.compare(baseline, released, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled), arguments: Render3DPostProcessGPUTests.Path.supported)
        func theFocusPlaneStaysSharpWhileOtherDistancesBlur(path: Render3DPostProcessGPUTests.Path) async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene(
                farMarker: true,
                antiAliasing: path == .fxaa ? .fxaa : .none,
                temporalRenderScale: path == .temporal ? 1 : nil
            )
            let frames = path == .temporal ? 16 : 6
            // The spheres stand 3.4 units from the camera and the dark marker 7.4 units away.
            try scene.configure { $0.postProcess.depthOfField = DepthOfField3D(isEnabled: true, focusDistance: 3.4, aperture: 2, maximumBlurRadius: 12) }
            let nearFocus = try await scene.render(.none, frames: frames)
            try scene.configure { $0.postProcess.depthOfField = DepthOfField3D(isEnabled: true, focusDistance: 7.4, aperture: 2, maximumBlurRadius: 12) }
            let farFocus = try await scene.render(.none, frames: frames)

            // Sphere silhouette: a row through the first sphere's lit left edge.
            let sphereNear = Self.horizontalSharpness(nearFocus, row: 215, columns: 70...130)
            let sphereFar = Self.horizontalSharpness(farFocus, row: 215, columns: 70...130)
            #expect(sphereNear > sphereFar * 1.4, "\(path): the spheres must be sharper when focus sits on them (\(sphereNear) vs \(sphereFar)).")
            // The marker's left edge against the sky, on the row through its center.
            let markerNear = Self.horizontalSharpness(nearFocus, row: 152, columns: 330...365)
            let markerFar = Self.horizontalSharpness(farFocus, row: 152, columns: 330...365)
            #expect(markerFar > markerNear * 1.4, "\(path): the far marker must be sharper when focus sits on it (\(markerFar) vs \(markerNear)).")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func aWiderApertureBlursMore() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            try scene.configure { $0.postProcess.depthOfField = DepthOfField3D(isEnabled: true, focusDistance: 8.4, aperture: 0.5, maximumBlurRadius: 16) }
            let narrow = Self.horizontalSharpness(try await scene.render(.none), row: 215, columns: 70...130)
            try scene.configure { $0.postProcess.depthOfField.aperture = 3 }
            let wide = Self.horizontalSharpness(try await scene.render(.none), row: 215, columns: 70...130)
            try scene.configure { $0.postProcess.depthOfField.maximumBlurRadius = 3 }
            let capped = Self.horizontalSharpness(try await scene.render(.none), row: 215, columns: 70...130)
            #expect(wide < narrow, "A wider aperture must blur the out-of-focus spheres more (\(wide) vs \(narrow)).")
            #expect(capped > wide, "A smaller maximum radius must bound the blur (\(capped) vs \(wide)).")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func aFullScreenDebugViewSkipsDepthOfFieldAndMatchesGoldenFrames() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene(farMarker: true)
            try scene.configure { $0.postProcess.depthOfField = DepthOfField3D(isEnabled: true, focusDistance: 3.4, aperture: 2, maximumBlurRadius: 12) }
            try Self.expectGolden(try await scene.render(.none), named: "pbr-spheres-dof-near-focus")
            try scene.configure { $0.postProcess.depthOfField.focusDistance = 7.4 }
            try Self.expectGolden(try await scene.render(.none), named: "pbr-spheres-dof-far-focus")
            // A normals view replaces the final image, and depth of field must not run on top of it.
            let withEffect = try await scene.render(.normals)
            try scene.configure { $0.postProcess.depthOfField.isEnabled = false }
            let without = try await scene.render(.normals)
            #expect(GoldenFrame.compare(withEffect, without, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
        }
    }
}
#endif
