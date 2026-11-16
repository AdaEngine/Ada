/// NVIDIA DLSS quality presets, ordered from native resolution to the lowest internal resolution.
public enum DLSSQualityPreset: String, Codable, CaseIterable, Sendable {
    case dlaa
    case quality
    case balanced
    case performance
    case ultraPerformance

    /// The internal-to-output resolution ratio of the preset.
    public var renderScale: Float {
        switch self {
        case .dlaa: 1
        case .quality: 2.0 / 3.0
        case .balanced: 0.58
        case .performance: 0.5
        case .ultraPerformance: 1.0 / 3.0
        }
    }

    /// The preset whose ``renderScale`` is closest to `scale`; out-of-range values clamp to the ends.
    public static func nearest(toRenderScale scale: Float) -> DLSSQualityPreset {
        guard scale.isFinite else { return .dlaa }
        var best = DLSSQualityPreset.dlaa
        var bestDistance = Float.infinity
        for preset in allCases {
            let distance = abs(preset.renderScale - scale)
            if distance < bestDistance {
                best = preset
                bestDistance = distance
            }
        }
        return best
    }
}
