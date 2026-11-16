/// What temporal reconstruction a view actually runs, for diagnostics and Studio.
public struct TemporalReconstructionStatus: Equatable, Sendable {
    /// The method the camera asked for.
    public var requested: TemporalReconstructionMethod
    /// The method in effect after availability was applied.
    public var active: TemporalReconstructionMethod
    /// The DLSS preset matching the camera's render scale; nil unless DLSS is active.
    public var dlssPreset: DLSSQualityPreset?
    /// Why the requested method was replaced, when it was.
    public var fallbackReason: String?

    public init(settings: TemporalUpscalingSettings, resolution: TemporalReconstructionResolution) {
        requested = settings.method
        active = resolution.method
        dlssPreset = resolution.method == .dlss ? DLSSQualityPreset.nearest(toRenderScale: settings.renderScale) : nil
        fallbackReason = resolution.fallbackReason
    }
}
