#if os(macOS) || os(Windows) || os(Linux)
import Foundation

/// CPU reference for the atmosphere integrals. Tests compare the GPU tables against it.
/// Units are meters and per-meter coefficients, matching the shader constants (Hillaire 2020).
enum AtmosphereReference {
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double
        static let zero = RGB(r: 0, g: 0, b: 0)
    }

    static let rayleighScattering = RGB(r: 5.802e-6, g: 13.558e-6, b: 33.1e-6)
    static let mieScattering = 3.996e-6
    static let mieExtinction = 4.4e-6 + 3.996e-6
    static let ozoneAbsorption = RGB(r: 0.650e-6, g: 1.881e-6, b: 0.085e-6)
    static let rayleighScaleHeight = 8_000.0
    static let mieScaleHeight = 1_200.0

    /// Rayleigh phase function, integrates to 1 over the sphere.
    static func rayleighPhase(_ cosTheta: Double) -> Double {
        3 / (16 * Double.pi) * (1 + cosTheta * cosTheta)
    }

    /// Henyey-Greenstein phase function, integrates to 1 over the sphere.
    static func henyeyGreenstein(_ cosTheta: Double, g: Double) -> Double {
        let denominator = 1 + g * g - 2 * g * cosTheta
        return (1 - g * g) / (4 * Double.pi * denominator * denominator.squareRoot())
    }

    /// Ozone density: a tent between 10 km and 40 km peaking at 25 km.
    static func ozoneDensity(altitude: Double) -> Double {
        if altitude <= 25_000 {
            return min(max((altitude - 10_000) / 15_000, 0), 1)
        }
        return min(max((40_000 - altitude) / 15_000, 0), 1)
    }

    /// Transmittance from a point `altitude` meters above the ground along a ray with the given
    /// zenith cosine, to the top of the atmosphere. `nil` when the ray hits the ground.
    static func transmittance(
        altitude: Double,
        cosZenith: Double,
        groundRadius: Double = 6_360_000,
        atmosphereHeight: Double = 100_000,
        steps: Int = 256
    ) -> RGB? {
        let originRadius = groundRadius + altitude
        let topRadius = groundRadius + atmosphereHeight
        // Ray / sphere: the nearest hit with the ground blocks the ray.
        let b = originRadius * cosZenith
        let groundDiscriminant = b * b - (originRadius * originRadius - groundRadius * groundRadius)
        if cosZenith < 0, groundDiscriminant >= 0, -b - groundDiscriminant.squareRoot() > 0 { return nil }
        let topDiscriminant = b * b - (originRadius * originRadius - topRadius * topRadius)
        guard topDiscriminant >= 0 else { return nil }
        let length = -b + topDiscriminant.squareRoot()
        guard length > 0 else { return nil }

        var rayleighDepth = 0.0, mieDepth = 0.0, ozoneDepth = 0.0
        let step = length / Double(steps)
        for index in 0..<steps {
            let t = (Double(index) + 0.5) * step
            let radius = (originRadius * originRadius + 2 * originRadius * cosZenith * t + t * t).squareRoot()
            let height = max(radius - groundRadius, 0)
            rayleighDepth += exp(-height / rayleighScaleHeight) * step
            mieDepth += exp(-height / mieScaleHeight) * step
            ozoneDepth += ozoneDensity(altitude: height) * step
        }
        func channel(_ rayleigh: Double, _ ozone: Double) -> Double {
            exp(-(rayleigh * rayleighDepth + mieExtinction * mieDepth + ozone * ozoneDepth))
        }
        return RGB(
            r: channel(rayleighScattering.r, ozoneAbsorption.r),
            g: channel(rayleighScattering.g, ozoneAbsorption.g),
            b: channel(rayleighScattering.b, ozoneAbsorption.b)
        )
    }

    /// Inverse of the shader's transmittance-table parametrization: the (radius, zenith cosine) a texel stores.
    static func transmittanceParameters(
        uv: (x: Double, y: Double),
        size: (width: Double, height: Double) = (256, 64),
        groundRadius: Double = 6_360_000,
        atmosphereHeight: Double = 100_000
    ) -> (radius: Double, cosZenith: Double) {
        let top = groundRadius + atmosphereHeight
        let unitX = min(max((uv.x - 0.5 / size.width) * size.width / (size.width - 1), 0), 1)
        let unitY = min(max((uv.y - 0.5 / size.height) * size.height / (size.height - 1), 0), 1)
        let horizon = (top * top - groundRadius * groundRadius).squareRoot()
        let rho = horizon * unitY
        let radius = (rho * rho + groundRadius * groundRadius).squareRoot()
        let dMin = top - radius
        let dMax = rho + horizon
        let distance = dMin + unitX * (dMax - dMin)
        let mu = distance < 0.001 ? 1 : (horizon * horizon - rho * rho - distance * distance) / (2 * radius * distance)
        return (radius, min(max(mu, -1), 1))
    }
}
#endif
