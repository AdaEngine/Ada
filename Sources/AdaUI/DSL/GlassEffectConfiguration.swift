//
//  GlassEffectConfiguration.swift
//  AdaEngine
//

import AdaUtils

/// Configuration for the glass (blur + tint) effect applied to a view.
public struct Glass: Sendable {
    /// Corner radius of the glass shape in logical pixels. Default: 32.
    public var cornerRadius: Float = 32.0
    /// Gaussian blur radius applied to the background, in logical pixels. Default: 10.
    public var blurRadius: Float = 10.0
    /// Strength of the frosted glass tint [0, 1]. Default: 0.14.
    public var glassTintStrength: Float = 0.14
    /// Strength of the edge shadow [0, 1]. Default: 0.03.
    public var edgeShadowStrength: Float = 0.03
    /// Overall opacity of the glass surface [0, 1]. Default: 0.36.
    /// Lower values make the glass more transparent; 1.0 is fully opaque.
    public var opacity: Float = 0.36
    /// Optional tint color blended over the glass surface. Alpha is multiplied by 0.3 in the shader.
    public var tintColor: Color?
    /// Controls how square vs organic the corner profile feels. Higher values sharpen the superellipse.
    public var cornerRoundnessExponent: Float = 4.8
    /// Simulated optical thickness of the glass in logical pixels.
    public var glassThickness: Float = 28.0
    /// Base refractive index used for depth-based edge refraction.
    public var refractiveIndex: Float = 1.12
    /// Chromatic dispersion strength applied to the refracted background.
    public var dispersionStrength: Float = 0.24
    /// Distance range used to build the Fresnel reflection near the contour.
    public var fresnelDistanceRange: Float = 140.0
    /// Overall Fresnel contribution.
    public var fresnelIntensity: Float = 0.64
    /// Sharpness bias for the Fresnel falloff.
    public var fresnelEdgeSharpness: Float = 0.18
    /// Distance range used by the directional glare band.
    public var glareDistanceRange: Float = 104.0
    /// Concentrates the glare into a tighter angular band.
    public var glareAngleConvergence: Float = 1.55
    /// Boosts the glare on the opposite side of the normal field.
    public var glareOppositeSideBias: Float = 1.18
    /// Overall glare intensity.
    public var glareIntensity: Float = 0.76
    /// Sharpness bias for glare falloff.
    public var glareEdgeSharpness: Float = 0.14
    /// Angular offset for the directional glare lobe in radians.
    public var glareDirectionOffset: Float = -0.24
    /// A Boolean value indicating whether the glass surface reacts to direct press interaction.
    public var isInteractive: Bool = false
    /// Scale applied while an interactive glass surface is pressed.
    public var interactiveScale: Float = 1.06

    public init() {}
}

extension Glass {
    /// Standard frosted glass: full blur and tinting. Mirrors Apple's `.regular`.
    public static var regular: Glass {
        var glass = Glass()
        glass.blurRadius = 14.0
        glass.glassTintStrength = 0.85
        glass.edgeShadowStrength = 0.01
        glass.opacity = 1.0
        glass.cornerRoundnessExponent = 4.8
        glass.glassThickness = 6.0
        glass.refractiveIndex = 1.10
        glass.dispersionStrength = 0.0
        glass.fresnelDistanceRange = 156.0
        glass.fresnelIntensity = 0.52
        glass.fresnelEdgeSharpness = 0.24
        glass.glareDistanceRange = 112.0
        glass.glareAngleConvergence = 1.9
        glass.glareOppositeSideBias = 1.22
        glass.glareIntensity = 0.30
        glass.glareEdgeSharpness = 0.18
        glass.glareDirectionOffset = -0.34
        glass.tintColor = Color(red: 0.97, green: 0.985, blue: 1.0, alpha: 0.07)
        return glass
    }

    /// Brighter glass for pressed interactive controls.
    public static var interaction: Glass {
        var glass = Self.regular
        glass.blurRadius = 15.5
        glass.glassTintStrength = 1.0
        glass.edgeShadowStrength = 0.02
        glass.fresnelIntensity = 0.96
        glass.glareIntensity = 1.0
        glass.tintColor = Color(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.16)
        return glass
    }

    /// Minimal glass: light blur, almost transparent. Mirrors Apple's `.clear`.
    ///
    /// Blur and tint strength are high enough for the shader to show visible lens warping;
    /// opacity stays low so the panel still reads as “clear”.
    public static var clear: Glass {
        var glass = Glass()
        glass.blurRadius = 2.5
        glass.glassTintStrength = 0.10
        glass.edgeShadowStrength = 0.01
        glass.opacity = 1.0
        glass.cornerRoundnessExponent = 4.4
        glass.glassThickness = 22.0
        glass.refractiveIndex = 1.12
        glass.dispersionStrength = 0.0
        glass.fresnelDistanceRange = 118.0
        glass.fresnelIntensity = 0.38
        glass.fresnelEdgeSharpness = 0.10
        glass.glareDistanceRange = 84.0
        glass.glareAngleConvergence = 1.45
        glass.glareOppositeSideBias = 1.0
        glass.glareIntensity = 0.28
        glass.glareEdgeSharpness = 0.08
        glass.glareDirectionOffset = -0.20
        glass.tintColor = Color(red: 0.98, green: 0.99, blue: 1.0, alpha: 0.03)
        return glass
    }

    /// No visible effect. Useful as an animation start/end state.
    public static var identity: Glass {
        var glass = Glass()
        glass.blurRadius = 0.0
        glass.glassTintStrength = 0.0
        glass.edgeShadowStrength = 0.0
        glass.opacity = 0.0
        glass.glassThickness = 0.0
        glass.dispersionStrength = 0.0
        glass.fresnelIntensity = 0.0
        glass.glareIntensity = 0.0
        glass.tintColor = .clear
        return glass
    }

    public func tint(_ color: Color?) -> Glass {
        var newValue = self
        newValue.tintColor = color
        return newValue
    }

    public func opacity(_ opacity: Float) -> Glass {
        var newValue = self
        newValue.opacity = opacity
        return newValue
    }

    public func blurRadius(_ radius: Float) -> Glass {
        var newValue = self
        newValue.blurRadius = radius
        return newValue
    }

    public func glassTintStrength(_ strength: Float) -> Glass {
        var newValue = self
        newValue.glassTintStrength = strength
        return newValue
    }

    public func edgeShadowStrength(_ strength: Float) -> Glass {
        var newValue = self
        newValue.edgeShadowStrength = strength
        return newValue
    }

    public func cornerRoundnessExponent(_ exponent: Float) -> Glass {
        var newValue = self
        newValue.cornerRoundnessExponent = exponent
        return newValue
    }

    public func glassThickness(_ thickness: Float) -> Glass {
        var newValue = self
        newValue.glassThickness = thickness
        return newValue
    }

    public func refractiveIndex(_ index: Float) -> Glass {
        var newValue = self
        newValue.refractiveIndex = index
        return newValue
    }

    public func dispersionStrength(_ strength: Float) -> Glass {
        var newValue = self
        newValue.dispersionStrength = strength
        return newValue
    }

    public func fresnelDistanceRange(_ range: Float) -> Glass {
        var newValue = self
        newValue.fresnelDistanceRange = range
        return newValue
    }

    public func fresnelIntensity(_ intensity: Float) -> Glass {
        var newValue = self
        newValue.fresnelIntensity = intensity
        return newValue
    }

    public func fresnelEdgeSharpness(_ sharpness: Float) -> Glass {
        var newValue = self
        newValue.fresnelEdgeSharpness = sharpness
        return newValue
    }

    public func glareDistanceRange(_ range: Float) -> Glass {
        var newValue = self
        newValue.glareDistanceRange = range
        return newValue
    }

    public func glareAngleConvergence(_ convergence: Float) -> Glass {
        var newValue = self
        newValue.glareAngleConvergence = convergence
        return newValue
    }

    public func glareOppositeSideBias(_ bias: Float) -> Glass {
        var newValue = self
        newValue.glareOppositeSideBias = bias
        return newValue
    }

    public func glareIntensity(_ intensity: Float) -> Glass {
        var newValue = self
        newValue.glareIntensity = intensity
        return newValue
    }

    public func glareEdgeSharpness(_ sharpness: Float) -> Glass {
        var newValue = self
        newValue.glareEdgeSharpness = sharpness
        return newValue
    }

    public func glareDirectionOffset(_ offset: Float) -> Glass {
        var newValue = self
        newValue.glareDirectionOffset = offset
        return newValue
    }

    public func interactive(_ isInteractive: Bool = true, scale: Float = 1.06) -> Glass {
        var newValue = self
        newValue.isInteractive = isInteractive
        newValue.interactiveScale = scale
        return newValue
    }
}
