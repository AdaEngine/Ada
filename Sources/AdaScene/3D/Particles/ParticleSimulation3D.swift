import AdaCorePipelines
import Foundation
import Math

/// Deterministic fixed-step simulation; one bounded buffer per emitter, no entity per particle.
struct ParticleSimulation3D: Sendable {
    private struct Particle: Sendable {
        var position: Vector3
        var velocity: Vector3
        var lifetime: Float
        var age: Float = 0
        var phase: Float
    }
    private var particles: [Particle] = []
    private var randomState: UInt64
    private var remainder: Double = 0
    private var emission: Double = 0
    private var elapsed: Double = 0
    private var started = false
    private static let step: Double = 1.0 / 120
    var particleCount: Int { particles.count }

    init(seed: Int) { randomState = UInt64(bitPattern: Int64(seed)) }

    mutating func emitBurst(settings: ParticleEmitter3D, transform: Transform3D) {
        let capacity = min(max(settings.maxParticles, 0), 4096)
        let count = min(max(settings.burstCount, 0), max(0, capacity - particles.count))
        for _ in 0..<count { spawn(settings, transform: transform) }
    }

    mutating func advance(by dt: Double, settings: ParticleEmitter3D, transform: Transform3D) {
        guard dt.isFinite, dt > 0, !settings.isPaused else { return }
        remainder += min(dt, 0.25)
        let capacity = min(max(settings.maxParticles, 0), 4096)
        if particles.count > capacity { particles.removeLast(particles.count - capacity) }
        while remainder + 1e-10 >= Self.step {
            remainder = max(0, remainder - Self.step)
            tick(settings, transform: transform, capacity: capacity)
        }
    }

    func forEachParticle(settings: ParticleEmitter3D, _ body: (Particle3DSample) -> Void) {
        for particle in particles {
            let progress = min(1, particle.age / particle.lifetime)
            let fadeIn = min(1, particle.age / 0.15)
            // Expansion conserves density and the final fade removes any pop on death.
            let size = finite(settings.initialSize, fallback: 0.35, max: 100)
                + finite(settings.expansionRate, fallback: 0.45, max: 100) * particle.age
            let weather = settings.particleStyle == 1 || settings.particleStyle == 2
            let fade = weather ? min(1, particle.age / 0.025) * min(1, (particle.lifetime - particle.age) / 0.1) : fadeIn * (1 - progress) * (1 - progress)
            let alpha = finite(settings.opacity, fallback: 0.3, max: 1) * fade
            body(Particle3DSample(
                position: particle.position, size: size, color: valid(settings.color) ? settings.color : [0.5, 0.5, 0.5],
                opacity: alpha, rotation: particle.phase + particle.age * 0.12,
                softDistance: max(0.001, finite(settings.softDistance, fallback: 0.25, max: 10)),
                style: min(2, max(0, settings.particleStyle)),
                aspectRatio: max(0.005, finite(settings.aspectRatio, fallback: 0.035, max: 1)), velocity: particle.velocity
            ))
        }
    }

    private mutating func tick(_ settings: ParticleEmitter3D, transform: Transform3D, capacity: Int) {
        let dt = Float(Self.step)
        let wind = valid(settings.wind) ? settings.wind : .zero
        let acceleration = valid(settings.acceleration) ? settings.acceleration : .zero
        let drag = finite(settings.drag, fallback: 0.5, max: 100)
        let turbulence = finite(settings.turbulence, fallback: 0.25, max: 100)
        var index = 0
        while index < particles.count {
            particles[index].age += dt
            if particles[index].age >= particles[index].lifetime {
                particles.swapAt(index, particles.count - 1)
                particles.removeLast()
                continue
            }
            let phase = particles[index].phase + particles[index].age * 1.7
            let eddy = Vector3(Math.sin(phase), Math.cos(phase * 1.3) * 0.5, Math.sin(phase * 0.7 + 2)) * turbulence
            particles[index].velocity += (acceleration + eddy) * dt
            let windBlend = Float(1 - Foundation.exp(-Double(drag * dt)))
            particles[index].velocity += (wind - particles[index].velocity) * windBlend
            particles[index].position += particles[index].velocity * dt
            if settings.collisionPlaneEnabled, settings.collisionPlaneHeight.isFinite,
               particles[index].position.y <= settings.collisionPlaneHeight {
                particles.swapAt(index, particles.count - 1)
                particles.removeLast()
                continue
            }
            index += 1
        }
        guard settings.isEmitting else { return }
        let duration = max(0.001, finite(settings.duration, fallback: 1, max: 3600))
        let interval = settings.loops ? Self.step : min(Self.step, max(0, Double(duration) - elapsed))
        guard interval > 0 else { return }
        var requested = 0
        if !started { requested = min(max(0, settings.burstCount), capacity); started = true }
        elapsed += Self.step
        emission += Double(finite(settings.emissionRate, fallback: 24, max: 10_000)) * interval
        let continuous = Int(emission)
        emission -= Double(continuous)
        requested += continuous
        for _ in 0..<min(requested, max(0, capacity - particles.count)) { spawn(settings, transform: transform) }
        if settings.loops, elapsed >= Double(duration) { elapsed.formTruncatingRemainder(dividingBy: Double(duration)); started = false }
    }

    private mutating func spawn(_ settings: ParticleEmitter3D, transform: Transform3D) {
        let radius = finite(settings.spawnRadius, fallback: 0.12, max: 100)
        let azimuth = random() * 2 * Float.pi
        let y = random() * 2 - 1
        let ring = Math.sqrt(max(0, 1 - y * y))
        let radialDistance = radius * Float(Foundation.pow(Double(random()), 1.0 / 3.0))
        var offset = Vector3(Math.cos(azimuth) * ring, y, Math.sin(azimuth) * ring) * radialDistance
        let box = settings.spawnBoxHalfExtents
        if valid(box), box.x > 0 || box.y > 0 || box.z > 0 {
            offset = Vector3(random() * 2 - 1, random() * 2 - 1, random() * 2 - 1) * max(box, .zero)
        }
        let velocity = valid(settings.initialVelocity) ? settings.initialVelocity : .zero
        let variation = valid(settings.velocityVariation) ? settings.velocityVariation : .zero
        let localVelocity = velocity + Vector3(random() * 2 - 1, random() * 2 - 1, random() * 2 - 1) * variation
        let lifetime = max(0.01, finite(settings.lifetime, fallback: 4, max: 120)
            + (random() * 2 - 1) * finite(settings.lifetimeVariation, fallback: 1, max: 120))
        let position = (transform * Vector4(offset, 1)).xyz
        let worldVelocity = (transform * Vector4(localVelocity, 0)).xyz
        guard valid(position), valid(worldVelocity) else { return }
        particles.append(Particle(position: position, velocity: worldVelocity, lifetime: lifetime, phase: random() * 2 * .pi))
    }

    private mutating func random() -> Float {
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        return Float(randomState >> 40) / Float(1 << 24)
    }
    private func finite(_ value: Float, fallback: Float, max upper: Float) -> Float {
        value.isFinite ? min(max(0, value), upper) : fallback
    }
    private func valid(_ value: Vector3) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
}
