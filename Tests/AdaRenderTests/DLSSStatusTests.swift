import AdaRender
import Testing

@Suite("DLSS per-view status")
struct DLSSStatusTests {
    @Test func activeDLSSReportsThePresetMatchingTheRenderScale() {
        let settings = TemporalUpscalingSettings(renderScale: 0.5, method: .dlss)
        let status = TemporalReconstructionStatus(settings: settings, resolution: settings.method.resolved(dlssAvailable: true, unavailableReason: nil))
        #expect(status.requested == .dlss && status.active == .dlss)
        #expect(status.dlssPreset == .performance)
        #expect(status.fallbackReason == nil)
    }

    @Test func fallbackKeepsTheRequestAndExplainsWhy() {
        let settings = TemporalUpscalingSettings(renderScale: 0.67, method: .dlss)
        let status = TemporalReconstructionStatus(settings: settings, resolution: settings.method.resolved(dlssAvailable: false, unavailableReason: "no RTX GPU"))
        #expect(status.requested == .dlss && status.active == .portable)
        #expect(status.dlssPreset == nil)
        #expect(status.fallbackReason == "no RTX GPU")
    }

    @Test func portableHasNoPresetOrReason() {
        let settings = TemporalUpscalingSettings(renderScale: 0.5, method: .portable)
        let status = TemporalReconstructionStatus(settings: settings, resolution: settings.method.resolved(dlssAvailable: true, unavailableReason: nil))
        #expect(status.active == .portable && status.dlssPreset == nil && status.fallbackReason == nil)
    }
}
