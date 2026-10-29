import Foundation

/// Display-referred lens effects, applied to the scene before overlays and UI.
/// All effects default to off; pixel-sized controls are independent of resolution.
public struct Lens3D: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    /// Positive barrel distortion. The image is cropped enough to avoid empty corners.
    public var distortion: Float
    /// Red/blue separation at the image corners, in output pixels. The centre is unchanged.
    public var chromaticAberration: Float
    /// Softness at the image periphery, in output pixels.
    public var edgeSoftness: Float
    /// Amplitude of monochromatic, temporally varying sensor grain in display color.
    public var filmGrain: Float
    /// Water on the lens, independent of optical profile enablement. 0 is completely dry.
    public var rainAmount: Float
    /// Caller-owned seconds, so droplets can freeze with gameplay pause.
    public var rainTime: Float

    public init(isEnabled: Bool = false, distortion: Float = 0, chromaticAberration: Float = 0,
                edgeSoftness: Float = 0, filmGrain: Float = 0, rainAmount: Float = 0, rainTime: Float = 0) {
        self.isEnabled = isEnabled
        self.distortion = distortion
        self.chromaticAberration = chromaticAberration
        self.edgeSoftness = edgeSoftness
        self.filmGrain = filmGrain
        self.rainAmount = rainAmount
        self.rainTime = rainTime
    }

    private enum CodingKeys: CodingKey { case isEnabled, distortion, chromaticAberration, edgeSoftness, filmGrain, rainAmount, rainTime }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        distortion = try values.decodeIfPresent(Float.self, forKey: .distortion) ?? 0
        chromaticAberration = try values.decodeIfPresent(Float.self, forKey: .chromaticAberration) ?? 0
        edgeSoftness = try values.decodeIfPresent(Float.self, forKey: .edgeSoftness) ?? 0
        filmGrain = try values.decodeIfPresent(Float.self, forKey: .filmGrain) ?? 0
        rainAmount = try values.decodeIfPresent(Float.self, forKey: .rainAmount) ?? 0
        rainTime = try values.decodeIfPresent(Float.self, forKey: .rainTime) ?? 0
    }

    var sanitized: Lens3D {
        Lens3D(isEnabled: isEnabled,
               distortion: finiteRenderValue(distortion, fallback: 0, range: 0...0.5),
               chromaticAberration: finiteRenderValue(chromaticAberration, fallback: 0, range: 0...8),
               edgeSoftness: finiteRenderValue(edgeSoftness, fallback: 0, range: 0...4),
               filmGrain: finiteRenderValue(filmGrain, fallback: 0, range: 0...0.15),
               rainAmount: finiteRenderValue(rainAmount, fallback: 0, range: 0...1),
               rainTime: finiteRenderValue(rainTime, fallback: 0, range: 0...1_000_000))
    }

    var changesImage: Bool {
        let value = sanitized
        return value.rainAmount > 0 || (value.isEnabled && (value.distortion > 0 || value.chromaticAberration > 0 || value.edgeSoftness > 0 || value.filmGrain > 0))
    }
}

/// Per-pixel motion blur from camera, rigid, skeletal and morph motion vectors.
/// The shutter angle specifies the fraction of the measured frame displacement to expose.
public struct MotionBlur3D: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var shutterAngle: Float
    /// Maximum full trail length in output pixels, bounding fast rotations and the sample footprint.
    public var maximumVelocity: Float
    public var sampleCount: Int

    public init(isEnabled: Bool = false, shutterAngle: Float = 180, maximumVelocity: Float = 24, sampleCount: Int = 8) {
        self.isEnabled = isEnabled
        self.shutterAngle = shutterAngle
        self.maximumVelocity = maximumVelocity
        self.sampleCount = sampleCount
    }

    private enum CodingKeys: CodingKey { case isEnabled, shutterAngle, maximumVelocity, sampleCount }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        shutterAngle = try values.decodeIfPresent(Float.self, forKey: .shutterAngle) ?? 180
        maximumVelocity = try values.decodeIfPresent(Float.self, forKey: .maximumVelocity) ?? 24
        sampleCount = try values.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 8
    }

    var sanitized: MotionBlur3D {
        MotionBlur3D(isEnabled: isEnabled,
                     shutterAngle: finiteRenderValue(shutterAngle, fallback: 180, range: 0...360),
                     maximumVelocity: finiteRenderValue(maximumVelocity, fallback: 24, range: 0...64),
                     sampleCount: min(max(sampleCount, 2), 16))
    }

    var changesImage: Bool {
        let value = sanitized
        return value.isEnabled && value.shutterAngle > 0 && value.maximumVelocity >= 0.5
    }
}
