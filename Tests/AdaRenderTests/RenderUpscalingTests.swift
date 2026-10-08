//
//  RenderUpscalingTests.swift
//  AdaEngine
//

@testable import AdaRender
import Math
import Testing

@Suite("Render Upscaling")
struct RenderUpscalingTests {
    @Test("Spatial upscaling reduces both render dimensions")
    func spatialUpscalingReducesRenderSize() {
        let size = resolveRenderSize(
            outputSize: SizeInt(width: 1_920, height: 1_080),
            mode: .spatial(renderScale: 0.75),
            supportsSpatialUpscaling: true
        )

        #expect(size == SizeInt(width: 1_440, height: 810))
    }

    @Test("Unsupported backends keep native resolution")
    func unsupportedBackendKeepsNativeResolution() {
        let outputSize = SizeInt(width: 1_920, height: 1_080)
        let size = resolveRenderSize(
            outputSize: outputSize,
            mode: .spatial(renderScale: 0.75),
            supportsSpatialUpscaling: false
        )

        #expect(size == outputSize)
    }

    @Test("Disabled upscaling keeps native resolution")
    func disabledUpscalingKeepsNativeResolution() {
        let outputSize = SizeInt(width: 1_920, height: 1_080)
        let size = resolveRenderSize(
            outputSize: outputSize,
            mode: .disabled,
            supportsSpatialUpscaling: true
        )

        #expect(size == outputSize)
    }

    @Test("Render scale is clamped to a safe range", arguments: [
        (scale: Float(0.1), expected: SizeInt(width: 500, height: 250)),
        (scale: Float(2), expected: SizeInt(width: 1_000, height: 500)),
    ])
    func renderScaleIsClamped(argument: (scale: Float, expected: SizeInt)) {
        let size = resolveRenderSize(
            outputSize: SizeInt(width: 1_000, height: 500),
            mode: .spatial(renderScale: argument.scale),
            supportsSpatialUpscaling: true
        )

        #expect(size == argument.expected)
    }

    @Test("Non-finite render scales keep native resolution", arguments: [Float.nan, .infinity])
    func nonFiniteRenderScaleKeepsNativeResolution(renderScale: Float) {
        let outputSize = SizeInt(width: 1_000, height: 500)
        let size = resolveRenderSize(
            outputSize: outputSize,
            mode: .spatial(renderScale: renderScale),
            supportsSpatialUpscaling: true
        )

        #expect(size == outputSize)
    }

    @Test("Fractional render sizes round up")
    func fractionalSizeRoundsUp() {
        let size = resolveRenderSize(
            outputSize: SizeInt(width: 101, height: 51),
            mode: .spatial(renderScale: 0.75),
            supportsSpatialUpscaling: true
        )

        #expect(size == SizeInt(width: 76, height: 39))
    }
}
