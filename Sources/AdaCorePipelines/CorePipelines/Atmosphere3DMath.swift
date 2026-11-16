//
//  Atmosphere3DMath.swift
//  AdaEngine
//

import Foundation
import Math

/// CPU-side atmosphere integrals that need one value rather than a table.
enum Atmosphere3DMath {
    /// The fraction of sunlight, per color channel, that reaches a camera `altitude` meters above the ground when the
    /// sun is in `sunDirection` (a vector toward the sun, world Y up). Zero once the planet blocks the sun.
    /// `atmosphere` must already be sanitized.
    static func sunTransmittance(atmosphere: Atmosphere3D, altitude: Float, sunDirection: Vector3) -> Vector3 {
        let ground = Double(atmosphere.groundRadiusMeters)
        let top = ground + Double(atmosphere.atmosphereHeightMeters)
        let radius = ground + Double(max(altitude, 0))
        let direction = sunDirection.normalized
        guard direction.x.isFinite, direction.y.isFinite, direction.z.isFinite else { return .zero }
        let mu = Double(direction.y)
        let groundDiscriminant = radius * radius * (mu * mu - 1) + ground * ground
        if mu < 0, groundDiscriminant >= 0 { return .zero }
        let length = max(0, -radius * mu + max(radius * radius * (mu * mu - 1) + top * top, 0).squareRoot())
        let steps = 64
        let step = length / Double(steps)
        var rayleighDepth = 0.0
        var mieDepth = 0.0
        var ozoneDepth = 0.0
        for index in 0..<steps {
            let travel = (Double(index) + 0.5) * step
            let sampleRadius = (radius * radius + travel * travel + 2 * radius * mu * travel).squareRoot()
            let height = max(sampleRadius - ground, 0)
            rayleighDepth += exp(-height / Double(Atmosphere3DUniform.rayleighScaleHeight)) * step
            mieDepth += exp(-height / Double(Atmosphere3DUniform.mieScaleHeight)) * step
            ozoneDepth += max(0, 1 - abs(height - 25_000) / 15_000) * step
        }
        let rayleigh = Atmosphere3DUniform.rayleighScattering * atmosphere.rayleighScale
        let ozone = Atmosphere3DUniform.ozoneAbsorption * atmosphere.ozoneScale
        let mieExtinction = (Atmosphere3DUniform.mieScattering + Atmosphere3DUniform.mieAbsorption) * atmosphere.mieScale
        func channel(_ rayleigh: Float, _ ozone: Float) -> Float {
            Float(exp(-(Double(rayleigh) * rayleighDepth + Double(mieExtinction) * mieDepth + Double(ozone) * ozoneDepth)))
        }
        return Vector3(channel(rayleigh.x, ozone.x), channel(rayleigh.y, ozone.y), channel(rayleigh.z, ozone.z))
    }
}
