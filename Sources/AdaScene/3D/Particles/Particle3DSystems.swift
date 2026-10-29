import AdaCorePipelines
import AdaECS
import AdaRender
import AdaTransform
import AdaUtils

@PlainSystem(dependencies: [.after(ChildTransformSystem.self)])
struct ParticleSimulation3DSystem {
    @Query<Ref<ParticleEmitter3D>, GlobalTransform> private var emitters
    @Res<DeltaTime> private var time
    init(world _: World) {}
    func update(context _: UpdateContext) {
        emitters.forEach { component, transform in
            var emitter = component.wrappedValue
            var simulation = emitter.simulation ?? ParticleSimulation3D(seed: emitter.seed)
            // Do not retain a second CoW particle buffer while updating it.
            emitter.simulation = nil
            component.simulation = nil
            if emitter.appliedRestartCount != emitter.restartCount { simulation = ParticleSimulation3D(seed: emitter.seed) }
            emitter.appliedRestartCount = emitter.restartCount
            if !emitter.isPaused, emitter.appliedBurstRequest != emitter.burstRequest {
                simulation.emitBurst(settings: emitter, transform: transform.matrix)
                emitter.appliedBurstRequest = emitter.burstRequest
            }
            simulation.advance(by: Double(time.deltaTime), settings: emitter, transform: transform.matrix)
            emitter.simulation = simulation
            component.wrappedValue = emitter
        }
    }
}

@PlainSystem
struct ExtractParticles3DSystem {
    @Extract<Query<Entity, ParticleEmitter3D, Visibility>> private var emitters
    @ResMut<ExtractedParticles3D> private var extracted
    init(world _: World) {}
    func update(context _: UpdateContext) {
        extracted.samples.removeAll(keepingCapacity: true)
        emitters.wrappedValue.forEach { _, emitter, visibility in
            guard visibility != .hidden else { return }
            emitter.simulation?.forEachParticle(settings: emitter) { sample in
                // Bound total upload and sort work across the complete scene.
                if extracted.samples.count < 65_536 { extracted.samples.append(sample) }
            }
        }
    }
}
