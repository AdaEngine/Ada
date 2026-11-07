import Foundation
import Math

struct TerrainBrushDab: Sendable {
    let center: Vector2
    let pressure: Float
    let exposure: Float
    let cosine: Double
    let sine: Double
}

extension TerrainHeightBrushStroke {
    static let maximumDabs = 4_096
    static let maximumVisits = 8_388_608

    func validate() throws {
        let s = settings
        guard s.radius.isFinite, s.radius > 0, s.strength.isFinite, s.strength >= 0,
            s.falloff.isFinite, (0...1).contains(s.falloff), s.spacing.isFinite, (0.01...2).contains(s.spacing),
            s.rotation.isFinite, s.rotationJitter.isFinite, (0...Float.pi).contains(s.rotationJitter),
            s.terraceStep.isFinite, s.terraceStep > 0, s.noiseAmplitude.isFinite, s.noiseAmplitude >= 0,
            s.talusAngle.isFinite, (0...89).contains(s.talusAngle), (1...64).contains(s.iterations),
            s.targetHeight?.isFinite != false
        else { throw TerrainHeightBrushError.invalidParameters }
        if s.operation == .setHeight, s.targetHeight == nil { throw TerrainHeightBrushError.invalidParameters }
        for range in [s.heightRange, s.slopeRange].compactMap({ $0 }) {
            guard range.lowerBound.isFinite, range.upperBound.isFinite else { throw TerrainHeightBrushError.invalidParameters }
        }
        if let range = s.slopeRange, range.lowerBound < 0 || range.upperBound > 90 { throw TerrainHeightBrushError.invalidParameters }
        if case let .alpha(alpha) = s.shape { try alpha.validate() }
        guard !points.isEmpty, points.count <= Self.maximumDabs else { throw TerrainHeightBrushError.invalidStroke }
        var previous = -Double.infinity
        for point in points {
            guard point.position.x.isFinite, point.position.y.isFinite, point.position.z.isFinite,
                point.time.isFinite, point.time >= previous, point.pressure.isFinite, (0...1).contains(point.pressure)
            else { throw TerrainHeightBrushError.invalidStroke }
            previous = point.time
        }
        if s.operation == .ramp, let a = points.first, let b = points.last {
            let dx = Double(b.position.x) - Double(a.position.x), dz = Double(b.position.z) - Double(a.position.z)
            guard dx * dx + dz * dz > 0 else { throw TerrainHeightBrushError.invalidStroke }
        }
    }

    func sampledDabs() throws -> [TerrainBrushDab] {
        try validate()
        guard let first = points.first, let last = points.last else { throw TerrainHeightBrushError.invalidStroke }
        if settings.operation.usesTime {
            let duration = last.time - first.time
            guard duration.isFinite, duration <= 60 else { throw TerrainHeightBrushError.tooManyDabs }
            if duration == 0 {
                return []
            }
            let count = Int((duration * 60).rounded(.up))
            guard count <= Self.maximumDabs else { throw TerrainHeightBrushError.tooManyDabs }
            var dabs: [TerrainBrushDab] = []
            var segment = 0
            for index in 0..<count {
                let start = Double(index) / 60, end = min(duration, Double(index + 1) / 60)
                let time = first.time + (start + end) / 2
                while segment + 1 < points.count - 1, points[segment + 1].time < time { segment += 1 }
                let a = points[segment], b = points[min(segment + 1, points.count - 1)]
                let t = b.time > a.time ? min(1, max(0, (time - a.time) / (b.time - a.time))) : 0
                dabs.append(dab(a: a, b: b, t: t, exposure: Float(end - start), index: index))
            }
            return dabs
        }
        let step = Double(settings.radius) * Double(settings.spacing)
        var lengths: [Double] = []
        var total = 0.0
        for index in 1..<points.count {
            let a = points[index - 1].position, b = points[index].position
            let dx = Double(b.x) - Double(a.x), dz = Double(b.z) - Double(a.z)
            let length = (dx * dx + dz * dz).squareRoot()
            lengths.append(length)
            total += length
        }
        guard total.isFinite, total / step <= Double(Self.maximumDabs - 2) else { throw TerrainHeightBrushError.tooManyDabs }
        var result = [dab(a: first, b: first, t: 0, exposure: 1, index: 0)]
        var traversed = 0.0, next = step
        for index in lengths.indices {
            let length = lengths[index]
            while length > 0, next <= traversed + length {
                result.append(dab(a: points[index], b: points[index + 1], t: (next - traversed) / length, exposure: 1, index: result.count))
                next += step
            }
            traversed += length
        }
        if total > 0, let tail = result.last,
            tail.center.x != last.position.x || tail.center.y != last.position.z {
            result.append(dab(a: last, b: last, t: 0, exposure: 1, index: result.count))
        }
        return result
    }

    private func dab(a: TerrainBrushPoint, b: TerrainBrushPoint, t: Double, exposure: Float, index: Int) -> TerrainBrushDab {
        let jitter = TerrainBrushMask.random(x: index, z: 0, seed: settings.seed)
        let angle = Double(settings.rotation) + Double(settings.rotationJitter) * jitter
        return .init(
            center: [
                Float(Double(a.position.x) + (Double(b.position.x) - Double(a.position.x)) * t),
                Float(Double(a.position.z) + (Double(b.position.z) - Double(a.position.z)) * t),
            ],
            pressure: Float(Double(a.pressure) + (Double(b.pressure) - Double(a.pressure)) * t),
            exposure: exposure,
            cosine: Math.cos(angle),
            sine: Math.sin(angle)
        )
    }
}

enum TerrainBrushMask {
    static func random(x: Int, z: Int, seed: UInt64) -> Double {
        var value = UInt64(bitPattern: Int64(x)) &* 0x9e37_79b9_7f4a_7c15
        value ^= UInt64(bitPattern: Int64(z)) &* 0xbf58_476d_1ce4_e5b9
        value ^= seed &+ 0x94d0_49bb_1331_11eb
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_991 * 2 - 1
    }

    static func weight(point: TerrainGridPoint, source: TerrainHeightStorage, dab: TerrainBrushDab, settings: TerrainHeightBrushSettings) -> Double {
        let x = (Double(source.origin.x) + Double(point.x) * Double(source.spacing) - Double(dab.center.x)) / Double(settings.radius)
        let z = (Double(source.origin.y) + Double(point.z) * Double(source.spacing) - Double(dab.center.y)) / Double(settings.radius)
        return sample(x: x, z: z, point: point, dab: dab, settings: settings)
    }

    static func weight(position: Vector2, point: TerrainGridPoint, dab: TerrainBrushDab, settings: TerrainHeightBrushSettings) -> Double {
        let x = (Double(position.x) - Double(dab.center.x)) / Double(settings.radius)
        let z = (Double(position.y) - Double(dab.center.y)) / Double(settings.radius)
        return sample(x: x, z: z, point: point, dab: dab, settings: settings)
    }

    private static func sample(x: Double, z: Double, point: TerrainGridPoint, dab: TerrainBrushDab, settings: TerrainHeightBrushSettings) -> Double {
        let c = dab.cosine, s = dab.sine
        let u = c * x + s * z, v = -s * x + c * z
        let radial = (u * u + v * v).squareRoot()
        switch settings.shape {
        case .softRound: return fade(radial, softness: Double(settings.falloff))
        case .hardRound: return radial < 1 ? 1 : 0
        case .square: return fade(max(abs(u), abs(v)), softness: Double(settings.falloff))
        case .ridge: return fade(abs(u), softness: Double(settings.falloff)) * fade(abs(v) * 4, softness: Double(settings.falloff))
        case .crater:
            guard radial < 1 else {
                return 0
            }
            if radial < 0.65 {
                let t = 1 - radial / 0.65
                return -t * t
            }
            return 0.35 * Math.sin(Double.pi * (radial - 0.65) / 0.35)
        case .ridgedNoise: return fade(radial, softness: Double(settings.falloff)) * (1 - abs(random(x: point.x, z: point.z, seed: settings.seed)))
        case let .alpha(alpha):
            guard abs(u) <= 1, abs(v) <= 1 else {
                return 0
            }
            let fx = (u + 1) / 2 * Double(alpha.width - 1), fz = (v + 1) / 2 * Double(alpha.height - 1)
            let x0 = Int(fx.rounded(.down)), z0 = Int(fz.rounded(.down)), x1 = min(alpha.width - 1, x0 + 1), z1 = min(alpha.height - 1, z0 + 1)
            let tx = fx - Double(x0), tz = fz - Double(z0)
            let a = Double(alpha.values[z0 * alpha.width + x0]), b = Double(alpha.values[z0 * alpha.width + x1])
            let c = Double(alpha.values[z1 * alpha.width + x0]), d = Double(alpha.values[z1 * alpha.width + x1])
            return ((a + (b - a) * tx) * (1 - tz) + (c + (d - c) * tx) * tz) / 255
        }
    }

    private static func fade(_ distance: Double, softness: Double) -> Double {
        guard distance < 1 else {
            return 0
        }
        guard softness > 0 else {
            return 1
        }
        let t = min(1, max(0, (1 - distance) / softness))
        return t * t * (3 - 2 * t)
    }
}
