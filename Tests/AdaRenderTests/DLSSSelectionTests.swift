import AdaRender
import Foundation
import Testing

@Suite("DLSS selection and presets")
struct DLSSSelectionTests {
    @Test func renderScaleMapsToTheNearestPreset() {
        #expect(DLSSQualityPreset.nearest(toRenderScale: 1) == .dlaa)
        #expect(DLSSQualityPreset.nearest(toRenderScale: 0.67) == .quality)
        #expect(DLSSQualityPreset.nearest(toRenderScale: 0.58) == .balanced)
        #expect(DLSSQualityPreset.nearest(toRenderScale: 0.5) == .performance)
        #expect(DLSSQualityPreset.nearest(toRenderScale: 0.33) == .ultraPerformance)
        #expect(DLSSQualityPreset.nearest(toRenderScale: 2) == .dlaa)
        #expect(DLSSQualityPreset.nearest(toRenderScale: 0.01) == .ultraPerformance)
    }

    @Test func presetScalesDescendFromNativeResolution() {
        let scales = [DLSSQualityPreset.dlaa, .quality, .balanced, .performance, .ultraPerformance].map(\.renderScale)
        #expect(scales == scales.sorted(by: >))
        #expect(scales.first == 1)
    }

    @Test func explicitDLSSUsesDLSSWhenAvailable() {
        let resolution = TemporalReconstructionMethod.dlss.resolved(dlssAvailable: true, unavailableReason: nil)
        #expect(resolution.method == .dlss && resolution.fallbackReason == nil)
    }

    @Test func explicitDLSSFallsBackToPortableWithAReason() {
        let resolution = TemporalReconstructionMethod.dlss.resolved(dlssAvailable: false, unavailableReason: "NGX runtime not found")
        #expect(resolution.method == .portable)
        #expect(resolution.fallbackReason == "NGX runtime not found")
    }

    @Test func automaticUsesDLSSWhenAvailableAndThePortableUpscalerOtherwise() {
        #expect(TemporalReconstructionMethod.automatic.resolved(dlssAvailable: true, unavailableReason: nil).method == .dlss)
        let fallback = TemporalReconstructionMethod.automatic.resolved(dlssAvailable: false, unavailableReason: "no RTX GPU")
        #expect(fallback.method == .portable && fallback.fallbackReason == nil)
    }

    @Test func portableIsNeverChanged() {
        #expect(TemporalReconstructionMethod.portable.resolved(dlssAvailable: true, unavailableReason: nil).method == .portable)
    }

    @Test func dlssMethodRoundTripsAndExistingScenesDecodeUnchanged() throws {
        let encoded = try JSONEncoder().encode(TemporalUpscalingSettings(renderScale: 0.5, method: .dlss))
        #expect(try JSONDecoder().decode(TemporalUpscalingSettings.self, from: encoded).method == .dlss)
        let legacy = try JSONDecoder().decode(TemporalUpscalingSettings.self, from: Data("{\"renderScale\":0.7}".utf8))
        #expect(legacy.method == .automatic)
    }
}
