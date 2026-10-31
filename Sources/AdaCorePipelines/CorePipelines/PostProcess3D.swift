import AdaAssets
import AdaRender
import Foundation

/// HDR bloom. Bright scene energy above `threshold` is blurred through a downsample/upsample chain and added
/// to the image before tone mapping, so it follows exposure and is clipped by the tone mapper like any light.
///
/// Bloom is built from the lit geometry. Pixels that only show the skybox do not contribute energy, though
/// bloom from geometry still spreads over them.
public struct Bloom3D: Codable, Sendable, Equatable {
    /// Whether the bloom chain is built and composited. Off by default; a disabled bloom allocates nothing.
    public var isEnabled: Bool
    /// Strength of the added glow. Typical values are `0.05...0.5`.
    public var intensity: Float
    /// Exposed scene luminance where bloom starts, in linear HDR units. `1` is display white before tone mapping.
    public var threshold: Float
    /// Width of the soft transition below `threshold`, as a fraction of it (`0...1`).
    public var softKnee: Float
    /// How strongly each wider level contributes (`0...1`). Higher values give a larger, softer glow.
    public var scatter: Float

    public init(isEnabled: Bool = false, intensity: Float = 0.2, threshold: Float = 1, softKnee: Float = 0.5, scatter: Float = 0.7) {
        self.isEnabled = isEnabled
        self.intensity = intensity
        self.threshold = threshold
        self.softKnee = softKnee
        self.scatter = scatter
    }

    private enum CodingKeys: CodingKey { case isEnabled, intensity, threshold, softKnee, scatter }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Bloom3D()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        intensity = try container.decodeIfPresent(Float.self, forKey: .intensity) ?? defaults.intensity
        threshold = try container.decodeIfPresent(Float.self, forKey: .threshold) ?? defaults.threshold
        softKnee = try container.decodeIfPresent(Float.self, forKey: .softKnee) ?? defaults.softKnee
        scatter = try container.decodeIfPresent(Float.self, forKey: .scatter) ?? defaults.scatter
    }

    /// Settings clamped to ranges the shaders handle, replacing non-finite values with defaults.
    var sanitized: Bloom3D {
        let defaults = Bloom3D()
        return Bloom3D(
            isEnabled: isEnabled,
            intensity: finiteRenderValue(intensity, fallback: defaults.intensity, range: 0...4),
            threshold: finiteRenderValue(threshold, fallback: defaults.threshold, range: 0...64),
            softKnee: finiteRenderValue(softKnee, fallback: defaults.softKnee, range: 0...1),
            scatter: finiteRenderValue(scatter, fallback: defaults.scatter, range: 0...1)
        )
    }
}

/// Depth of field: surfaces away from `focusDistance` blur with a bokeh-disc gather.
///
/// It runs on the final display color after tone mapping and anti-aliasing, using the view-space depth the
/// main pass already writes. Pixels without geometry (the sky) count as infinitely far. Because it works on
/// display values, very bright highlights do not bloom into bokeh balls the way they would in linear HDR.
public struct DepthOfField3D: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    /// Distance from the camera, along the view axis, that stays sharp.
    public var focusDistance: Float
    /// Blur growth with distance from the focus plane. Larger values give a shallower field.
    public var aperture: Float
    /// Largest blur radius in pixels at the output resolution, which bounds the cost.
    public var maximumBlurRadius: Float

    public init(isEnabled: Bool = false, focusDistance: Float = 5, aperture: Float = 1, maximumBlurRadius: Float = 10) {
        self.isEnabled = isEnabled
        self.focusDistance = focusDistance
        self.aperture = aperture
        self.maximumBlurRadius = maximumBlurRadius
    }

    private enum CodingKeys: CodingKey { case isEnabled, focusDistance, aperture, maximumBlurRadius }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DepthOfField3D()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        focusDistance = try container.decodeIfPresent(Float.self, forKey: .focusDistance) ?? defaults.focusDistance
        aperture = try container.decodeIfPresent(Float.self, forKey: .aperture) ?? defaults.aperture
        maximumBlurRadius = try container.decodeIfPresent(Float.self, forKey: .maximumBlurRadius) ?? defaults.maximumBlurRadius
    }

    var sanitized: DepthOfField3D {
        let defaults = DepthOfField3D()
        return DepthOfField3D(
            isEnabled: isEnabled,
            focusDistance: finiteRenderValue(focusDistance, fallback: defaults.focusDistance, range: 0.05...10000),
            aperture: finiteRenderValue(aperture, fallback: defaults.aperture, range: 0...20),
            maximumBlurRadius: finiteRenderValue(maximumBlurRadius, fallback: defaults.maximumBlurRadius, range: 0...32)
        )
    }

    /// Whether the effect changes the image at all for these settings.
    var changesImage: Bool {
        let settings = sanitized
        return settings.isEnabled && settings.aperture > 0 && settings.maximumBlurRadius >= 0.5
    }
}

/// Automatic exposure that meters the lit scene and adapts toward a mid-gray average.
///
/// Exposure starts at 0 EV (kept inside the limits) and adapts at the configured speeds; use `infinity` speeds
/// to follow the scene instantly. The meter averages the logarithmic luminance of lit pixels covered by
/// geometry, so a frame that shows only sky keeps its exposure. The automatic result, limited to `minimumEV...maximumEV`, is added to the manual
/// ``PostProcess3D/exposureEV``, which therefore acts as exposure compensation.
public struct AutoExposure3D: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    /// Lowest automatic correction in stops. A bright scene cannot be darkened below this.
    public var minimumEV: Float
    /// Highest automatic correction in stops. A dim scene cannot be brightened beyond this.
    public var maximumEV: Float
    /// Exponential rate (1/seconds) when gain rises in darkness; 1 reaches 63% of the remaining EV change
    /// in one second. Zero holds exposure, `infinity` snaps instantly. This is not stops per second.
    public var speedUp: Float
    /// Exponential rate (1/seconds) when gain falls in brighter light. Use a larger value than speedUp for
    /// faster adaptation when leaving darkness. Zero holds exposure, `infinity` snaps instantly.
    public var speedDown: Float

    public init(isEnabled: Bool = false, minimumEV: Float = -3, maximumEV: Float = 3, speedUp: Float = 1, speedDown: Float = 2.5) {
        self.isEnabled = isEnabled
        self.minimumEV = minimumEV
        self.maximumEV = maximumEV
        self.speedUp = speedUp
        self.speedDown = speedDown
    }

    private enum CodingKeys: CodingKey { case isEnabled, minimumEV, maximumEV, speedUp, speedDown }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AutoExposure3D()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        minimumEV = try container.decodeIfPresent(Float.self, forKey: .minimumEV) ?? defaults.minimumEV
        maximumEV = try container.decodeIfPresent(Float.self, forKey: .maximumEV) ?? defaults.maximumEV
        speedUp = try container.decodeIfPresent(Float.self, forKey: .speedUp) ?? defaults.speedUp
        speedDown = try container.decodeIfPresent(Float.self, forKey: .speedDown) ?? defaults.speedDown
    }

    /// Largest speed passed to the shader. It is large enough that one frame reaches the target.
    static let snapSpeed: Float = 1e7

    /// Values the shader can use: ordered limits within ±10 stops and finite speeds, with `infinity` kept as a snap.
    var sanitized: AutoExposure3D {
        let defaults = AutoExposure3D()
        func speed(_ value: Float, fallback: Float) -> Float {
            value == .infinity ? Self.snapSpeed : finiteRenderValue(value, fallback: fallback, range: 0...1000)
        }
        let low = finiteRenderValue(minimumEV, fallback: defaults.minimumEV, range: -10...10)
        let high = finiteRenderValue(maximumEV, fallback: defaults.maximumEV, range: -10...10)
        return AutoExposure3D(
            isEnabled: isEnabled,
            minimumEV: min(low, high),
            maximumEV: max(low, high),
            speedUp: speed(speedUp, fallback: defaults.speedUp),
            speedDown: speed(speedDown, fallback: defaults.speedDown)
        )
    }
}

/// Darkens the image toward its corners. Applied to linear HDR before tone mapping.
public struct Vignette3D: Codable, Sendable, Equatable {
    /// Strength at the corners: `0` is off (the default), `1` fades the corners to black.
    public var intensity: Float
    /// Distance from the center, as a fraction of the distance to a corner, where darkening begins.
    public var radius: Float
    /// Width of the fade-in beyond `radius`, as a fraction of the corner distance.
    public var smoothness: Float

    public init(intensity: Float = 0, radius: Float = 0.75, smoothness: Float = 0.4) {
        self.intensity = intensity
        self.radius = radius
        self.smoothness = smoothness
    }

    private enum CodingKeys: CodingKey { case intensity, radius, smoothness }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Vignette3D()
        intensity = try container.decodeIfPresent(Float.self, forKey: .intensity) ?? defaults.intensity
        radius = try container.decodeIfPresent(Float.self, forKey: .radius) ?? defaults.radius
        smoothness = try container.decodeIfPresent(Float.self, forKey: .smoothness) ?? defaults.smoothness
    }

    var sanitized: Vignette3D {
        let defaults = Vignette3D()
        return Vignette3D(
            intensity: finiteRenderValue(intensity, fallback: defaults.intensity, range: 0...1),
            radius: finiteRenderValue(radius, fallback: defaults.radius, range: 0...2),
            smoothness: finiteRenderValue(smoothness, fallback: defaults.smoothness, range: 0.01...2)
        )
    }
}

/// Artistic color controls. `saturation` and `contrast` act on linear HDR before tone mapping; the optional
/// `lut` or `curves` is applied to the display-referred color after tone mapping according to `correctionMode`.
///
/// The LUT is a strip texture of `N` tiles side by side, each `N` by `N` pixels, so it is `N*N` wide and `N`
/// tall (for example 256 by 16 for `N = 16`). Red grows along x inside a tile, green grows down the rows
/// (row 0 is green 0), and blue selects the tile. It is sampled without sRGB decoding. An identity strip
/// leaves the image unchanged.
public struct ColorGrading3D: Codable, Sendable, Equatable {
    /// `1` is unchanged, `0` is grayscale, above `1` oversaturates.
    public var saturation: Float
    /// `1` is unchanged. Above `1` pushes values away from mid gray (0.18), below `1` pulls them toward it.
    public var contrast: Float
    /// Optional color lookup table in the strip layout above.
    public var lut: AssetHandle<Texture2D>?
    /// Blend strength for both correction modes: `0` preserves the display color, `1` applies correction fully.
    public var lutIntensity: Float
    /// Selects curves or an imported LUT. Defaults to LUT for compatibility with existing scenes.
    public var correctionMode: ColorCorrectionMode3D
    public var curves: ColorCurves3D

    public init(
        saturation: Float = 1, contrast: Float = 1, lut: AssetHandle<Texture2D>? = nil, lutIntensity: Float = 1,
        correctionMode: ColorCorrectionMode3D = .lut, curves: ColorCurves3D = ColorCurves3D()
    ) {
        self.saturation = saturation
        self.contrast = contrast
        self.lut = lut
        self.lutIntensity = lutIntensity
        self.correctionMode = correctionMode
        self.curves = curves
    }

    private enum CodingKeys: CodingKey { case saturation, contrast, lut, lutIntensity, correctionMode, curves }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ColorGrading3D()
        saturation = try container.decodeIfPresent(Float.self, forKey: .saturation) ?? defaults.saturation
        contrast = try container.decodeIfPresent(Float.self, forKey: .contrast) ?? defaults.contrast
        lut = try container.decodeIfPresent(AssetHandle<Texture2D>.self, forKey: .lut)
        lutIntensity = try container.decodeIfPresent(Float.self, forKey: .lutIntensity) ?? defaults.lutIntensity
        correctionMode = try container.decodeIfPresent(ColorCorrectionMode3D.self, forKey: .correctionMode) ?? defaults.correctionMode
        curves = try container.decodeIfPresent(ColorCurves3D.self, forKey: .curves) ?? defaults.curves
    }

    /// Handles are compared by identity: two settings match when they share the same loaded handle.
    public static func == (lhs: ColorGrading3D, rhs: ColorGrading3D) -> Bool {
        lhs.saturation == rhs.saturation && lhs.contrast == rhs.contrast && lhs.lut === rhs.lut && lhs.lutIntensity == rhs.lutIntensity
            && lhs.correctionMode == rhs.correctionMode && lhs.curves == rhs.curves
    }

    var sanitized: ColorGrading3D {
        ColorGrading3D(
            saturation: finiteRenderValue(saturation, fallback: 1, range: 0...3),
            contrast: finiteRenderValue(contrast, fallback: 1, range: 0.1...3),
            lut: lut,
            lutIntensity: finiteRenderValue(lutIntensity, fallback: 1, range: 0...1),
            correctionMode: correctionMode,
            curves: curves
        )
    }

    /// The LUT texture to bind and the intensity to apply, or no LUT while the asset is missing or unloaded.
    var activeLUT: (texture: Texture2D, intensity: Float)? {
        let settings = sanitized
        guard settings.correctionMode == .lut, settings.lutIntensity > 0, let texture = settings.lut?.asset,
            texture.height >= 2, texture.height <= 256, texture.width == texture.height * texture.height else {
            return nil
        }
        return (texture, settings.lutIntensity)
    }
}

/// Curve that maps linear HDR scene color to the displayable range, applied once after exposure and bloom.
public enum ToneMapper3D: String, Codable, Sendable, CaseIterable {
    /// ACES filmic fit. The original and default look: strong contrast, hue shifts in saturated highlights.
    case aces
    /// Khronos PBR Neutral. Leaves colors below the compression point nearly untouched, so authored
    /// base colors and textures read as designed; highlights roll off and desaturate gently.
    case neutral
    /// No curve. Values above `1` clip to white, which is useful for checking raw energy.
    case none

    /// Shader selector shared with `Tonemapping.glsl`. `aces` stays `0` so unset data keeps the old output.
    var shaderMode: Float {
        switch self {
        case .aces: 0
        case .neutral: 1
        case .none: 2
        }
    }
}

/// Per-camera controls applied to the linear HDR image before and during tone mapping. UI is never affected.
public struct PostProcess3D: Codable, Sendable, Equatable {
    /// Manual exposure compensation in stops (EV). `0` leaves the image unchanged; `+1` doubles brightness.
    public var exposureEV: Float
    public var bloom: Bloom3D
    /// Tone-mapping curve. Defaults to ``ToneMapper3D/aces``, the behavior before this setting existed.
    public var toneMapper: ToneMapper3D
    public var vignette: Vignette3D
    public var colorGrading: ColorGrading3D
    public var autoExposure: AutoExposure3D
    public var depthOfField: DepthOfField3D
    public var lens: Lens3D
    public var motionBlur: MotionBlur3D

    public init(
        exposureEV: Float = 0,
        bloom: Bloom3D = Bloom3D(),
        toneMapper: ToneMapper3D = ToneMapper3D.aces,
        vignette: Vignette3D = Vignette3D(),
        colorGrading: ColorGrading3D = ColorGrading3D(),
        autoExposure: AutoExposure3D = AutoExposure3D(),
        depthOfField: DepthOfField3D = DepthOfField3D(),
        lens: Lens3D = Lens3D(),
        motionBlur: MotionBlur3D = MotionBlur3D()
    ) {
        self.exposureEV = exposureEV
        self.bloom = bloom
        self.toneMapper = toneMapper
        self.vignette = vignette
        self.colorGrading = colorGrading
        self.autoExposure = autoExposure
        self.depthOfField = depthOfField
        self.lens = lens
        self.motionBlur = motionBlur
    }

    private enum CodingKeys: CodingKey { case exposureEV, bloom, toneMapper, vignette, colorGrading, autoExposure, depthOfField, lens, motionBlur }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposureEV = try container.decodeIfPresent(Float.self, forKey: .exposureEV) ?? 0
        bloom = try container.decodeIfPresent(Bloom3D.self, forKey: .bloom) ?? Bloom3D()
        toneMapper = try container.decodeIfPresent(ToneMapper3D.self, forKey: .toneMapper) ?? ToneMapper3D.aces
        vignette = try container.decodeIfPresent(Vignette3D.self, forKey: .vignette) ?? Vignette3D()
        colorGrading = try container.decodeIfPresent(ColorGrading3D.self, forKey: .colorGrading) ?? ColorGrading3D()
        autoExposure = try container.decodeIfPresent(AutoExposure3D.self, forKey: .autoExposure) ?? AutoExposure3D()
        depthOfField = try container.decodeIfPresent(DepthOfField3D.self, forKey: .depthOfField) ?? DepthOfField3D()
        lens = try container.decodeIfPresent(Lens3D.self, forKey: .lens) ?? Lens3D()
        motionBlur = try container.decodeIfPresent(MotionBlur3D.self, forKey: .motionBlur) ?? MotionBlur3D()
    }

    /// Linear multiplier for `exposureEV`, limited to ±10 stops so a bad value cannot overflow half floats.
    var exposureScale: Float {
        Float(pow(2.0, Double(finiteRenderValue(exposureEV, fallback: 0, range: -10...10))))
    }
}
