@testable import AdaScene
import AdaCorePipelines
import Foundation
import Math
import Testing

@Suite("3D particle simulation")
struct Particle3DTests {
    @Test func boxPrecipitationFillsTheEyeNeighborhoodWithoutAHollowShell() {
        var settings = ParticleEmitter3D()
        settings.spawnBoxHalfExtents = [2, 2, 2]
        settings.burstCount = 1024; settings.maxParticles = 1024; settings.emissionRate = 0
        settings.loops = false; settings.particleStyle = 1; settings.initialSize = 0.3
        settings.initialVelocity = .zero; settings.velocityVariation = .zero
        settings.acceleration = .zero; settings.wind = .zero; settings.turbulence = 0; settings.drag = 0
        var simulation = ParticleSimulation3D(seed: 173)
        simulation.advance(by: 0.1, settings: settings, transform: .identity)
        let values = samples(simulation, settings)
        #expect(values.count == 1024)
        #expect(values.allSatisfy { abs($0.position.x) <= 2 && abs($0.position.y) <= 2 && abs($0.position.z) <= 2 })
        #expect(values.contains { $0.position.length < 0.65 })
        #expect(values.allSatisfy { $0.style == 1 && $0.aspectRatio == 0.035 })
    }

    @Test func rainFallsInWorldYAndStopsAtTheGround() throws {
        var settings = ParticleEmitter3D()
        settings.spawnRadius = 0; settings.burstCount = 1; settings.emissionRate = 0; settings.loops = false
        settings.particleStyle = 1; settings.initialVelocity = [0, -16, 0]; settings.velocityVariation = .zero
        settings.acceleration = .zero; settings.drag = 0; settings.turbulence = 0
        settings.collisionPlaneEnabled = true; settings.collisionPlaneHeight = 0
        var simulation = ParticleSimulation3D(seed: 1)
        let source = Transform3D(translation: [0, 1, 0], rotation: .identity, scale: .one)
        simulation.advance(by: 0.025, settings: settings, transform: source)
        let particle = try #require(samples(simulation, settings).first)
        #expect(particle.position.y < 1 && particle.position.y > 0)
        #expect(particle.velocity.y == -16)
        simulation.advance(by: 0.1, settings: settings, transform: source)
        #expect(simulation.particleCount == 0)
    }

    private func samples(_ simulation: ParticleSimulation3D, _ settings: ParticleEmitter3D) -> [Particle3DSample] {
        var result: [Particle3DSample] = []
        simulation.forEachParticle(settings: settings) { result.append($0) }
        return result
    }

    @Test func deterministicAcrossFrameRatesAndBounded() {
        var settings = ParticleEmitter3D()
        settings.maxParticles = 20
        settings.emissionRate = 80
        var a = ParticleSimulation3D(seed: 7), b = ParticleSimulation3D(seed: 7)
        for _ in 0..<120 { a.advance(by: 1 / 60, settings: settings, transform: .identity) }
        for _ in 0..<60 { b.advance(by: 1 / 30, settings: settings, transform: .identity) }
        #expect(a.particleCount == 20 && b.particleCount == 20)
        let left = samples(a, settings), right = samples(b, settings)
        #expect(zip(left, right).allSatisfy { ($0.position - $1.position).length < 0.00001 })
    }

    @Test func smokeExpandsFadesDriftsAndExpiresAfterEmissionStops() throws {
        var settings = ParticleEmitter3D()
        settings.burstCount = 1; settings.emissionRate = 0; settings.loops = false
        settings.lifetime = 2; settings.lifetimeVariation = 0; settings.spawnRadius = 0
        settings.velocityVariation = .zero; settings.turbulence = 0
        settings.wind = [1, 0, 0]
        var simulation = ParticleSimulation3D(seed: 1)
        simulation.advance(by: 0.2, settings: settings, transform: .identity)
        let young = try #require(samples(simulation, settings).first)
        settings.isEmitting = false
        for _ in 0..<5 { simulation.advance(by: 0.2, settings: settings, transform: Transform3D(translation: [100, 0, 0], rotation: .identity, scale: .one)) }
        let old = try #require(samples(simulation, settings).first)
        #expect(old.size > young.size && old.opacity < young.opacity)
        #expect(old.position.x > young.position.x && old.position.x < 2)
        #expect(old.position.y > young.position.y)
        settings.isPaused = true
        simulation.advance(by: 0.2, settings: settings, transform: .identity)
        #expect(try #require(samples(simulation, settings).first).position == old.position)
        settings.isPaused = false
        for _ in 0..<6 { simulation.advance(by: 0.2, settings: settings, transform: .identity) }
        #expect(simulation.particleCount == 0)
    }

    @Test func partialScenesRoundTripAndInvalidSettingsStayFinite() throws {
        var settings = try JSONDecoder().decode(ParticleEmitter3D.self, from: Data("{}".utf8))
        #expect(settings.emissionRate == 24 && settings.maxParticles == 256)
        settings.emissionRate = .infinity; settings.lifetime = .nan; settings.wind = [.nan, 0, 0]
        settings.maxParticles = 3; settings.burstCount = Int.max
        var simulation = ParticleSimulation3D(seed: 1)
        simulation.advance(by: .infinity, settings: settings, transform: .identity)
        #expect(simulation.particleCount == 0)
        simulation.advance(by: 0.2, settings: settings, transform: .identity)
        #expect(simulation.particleCount == 3)
        #expect(samples(simulation, settings).allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.size.isFinite })
        let restored = try JSONDecoder().decode(ParticleEmitter3D.self, from: JSONEncoder().encode(ParticleEmitter3D()))
        #expect(restored.initialVelocity == Vector3(0, 0.8, 0) && restored.particleCount == 0)
    }

    @Test func repeatedBurstsPreservePreviousSmoke() {
        var settings = ParticleEmitter3D()
        settings.isEmitting = false; settings.burstCount = 4; settings.maxParticles = 10
        var simulation = ParticleSimulation3D(seed: 1)
        simulation.emitBurst(settings: settings, transform: .identity)
        simulation.advance(by: 0.2, settings: settings, transform: .identity)
        #expect(simulation.particleCount == 4)
        simulation.emitBurst(settings: settings, transform: .identity)
        #expect(simulation.particleCount == 8)
        simulation.emitBurst(settings: settings, transform: .identity)
        #expect(simulation.particleCount == 10)
        let arraySettings = try? JSONDecoder().decode(ParticleEmitter3D.self, from: Data(#"{"wind":[1,2,3]}"#.utf8))
        #expect(arraySettings?.wind == Vector3(1, 2, 3))
    }
}
