import AdaAnimation
import AdaECS
import AdaPhysics
import AdaTransform
import Foundation

struct CharacterLocomotion3DRuntime: Equatable, Sendable {
    var motion = CharacterLocomotion3DMotion()
    var diagnostic: Locomotion.Diagnostic?
    var lastStep: UInt64?
    var resetGeneration: UInt64?
    private var binding: Binding?
    private var applied: CharacterLocomotion3DRequest?

    private struct Binding: Equatable, Sendable {
        let owner: ObjectIdentifier
        let player: UUID
        let configuration: Locomotion.Configuration
    }

    mutating func release(_ reason: Locomotion.Diagnostic? = nil) {
        binding = nil
        diagnostic = reason
        resetMotion()
    }

    mutating func resetMotion() {
        motion = .init()
        applied = nil
    }

    mutating func bind(owner: Entity, player: SkeletalAnimationPlayer, configuration: Locomotion.Configuration) {
        let next = Binding(owner: ObjectIdentifier(owner), player: player.instanceID, configuration: configuration)
        guard configuration.isValid else {
            release(.invalidTuning)
            return
        }
        guard binding != next else {
            return
        }
        resetMotion()
        binding = next
        diagnostic = configuration.validateClips(player.clips)
    }

    mutating func apply(to player: inout SkeletalAnimationPlayer, configuration: Locomotion.Configuration) -> Bool {
        guard diagnostic == nil, let request = motion.request else {
            return false
        }
        let previous = applied
        let currentClip = player.clipIndex.map { player.clips[$0] }
        let sameActivation = previous?.activation == request.activation
        let sameGaitClip = previous?.state.isGait == true && request.state.isGait && previous?.clip == request.clip
        applied = request
        if currentClip?.name == request.clip, sameActivation || sameGaitClip {
            guard player.speed != request.speed else {
                return false
            }
            player.speed = request.speed
            return true
        }

        let syncGait = previous?.state.isGait == true && request.state.isGait && player.repeats
        var start = 0.0
        if syncGait, let currentClip, currentClip.duration > 0, let nextClip = player.clips.first(where: { $0.name == request.clip }) {
            let remainder = player.time.truncatingRemainder(dividingBy: currentClip.duration)
            let phase = (remainder < 0 ? remainder + currentClip.duration : remainder) / currentClip.duration
            start = phase * nextClip.duration
        }
        let duration = request.state.loops && previous?.state.loops != false ? configuration.gaitTransitionDuration : configuration.airTransitionDuration
        player.repeats = request.state.loops
        player.speed = request.speed
        do throws(SkeletalAnimationError) {
            try player.play(request.clip, transitionDuration: duration, startTime: start)
            return true
        } catch {
            release(.missingClip(request.clip))
            return false
        }
    }
}

private extension Locomotion.Configuration {
    var isValid: Bool {
        walkReferenceSpeed.isFinite && walkReferenceSpeed > 0
            && runReferenceSpeed.isFinite && runReferenceSpeed > 0
            && gaitTransitionDuration.isFinite && gaitTransitionDuration >= 0
            && airTransitionDuration.isFinite && airTransitionDuration >= 0
            && landingDuration.isFinite && landingDuration > 0
    }

    func validateClips(_ available: [SkeletalAnimationClip]) -> Locomotion.Diagnostic? {
        let required = [clips.idle, clips.walk, clips.run, clips.jump, clips.fall, clips.land]
        let directions = [left.walk, left.run, right.walk, right.run, back.walk, back.run].compactMap { $0 }
        for name in required + directions {
            guard !name.isEmpty else {
                return .missingClip(name)
            }
            let matches = available.count { $0.name == name }
            if matches == 0 {
                return .missingClip(name)
            }
            if matches > 1 {
                return .ambiguousClip(name)
            }
        }
        return nil
    }
}

private extension Locomotion {
    /// The systems declare reads for these indexed owner and model lookups.
    mutating func resolveTarget(
        owner: Entity,
        in world: World,
        hasController: Bool,
        hasTransform: Bool
    ) -> Entity.ID? {
        guard isEnabled, owner.isActive else {
            runtime.release()
            return nil
        }
        guard hasController, hasTransform, owner.components[PhysicsBody3DComponent.self] == nil,
            owner.components[RelationshipComponent.self]?.parent == nil
        else {
            runtime.release(.requiresRootCharacter)
            return nil
        }
        guard let source = owner.components[Model3DSource.self] else {
            runtime.release(.modelUnavailable)
            return nil
        }
        guard source.animationGraph == nil, owner.components[ModelAnimationPlayback3DComponent.self] == nil else {
            runtime.release(.playbackConflict)
            return nil
        }
        guard let root = owner.components[Model3DSourceState.self]?.rootEntityID,
            world.getEntityByID(root)?.isActive == true,
            let animation = world.get(ModelAnimation3DComponent.self, from: root)
        else {
            runtime.release(.modelUnavailable)
            return nil
        }
        guard animation.player.graph == nil else {
            runtime.release(.playbackConflict)
            return nil
        }
        runtime.bind(owner: owner, player: animation.player, configuration: configuration)
        return runtime.diagnostic == nil ? root : nil
    }
}

@PlainSystem
struct CharacterLocomotion3DFixedSystem {
    @Query<Entity, Ref<Locomotion>, Ref<Transform>?, CharacterController3DComponent?> private var owners
    @Query<Model3DSource, Model3DSourceState, ModelAnimationPlayback3DComponent,
           PhysicsBody3DComponent, RelationshipComponent, ModelAnimation3DComponent> private var bindingAccess
    @Res<PhysicsSimulationGate3D?> private var gate

    init(world _: World) {}

    func update(context: UpdateContext) {
        _ = bindingAccess
        let physicsIsReady = gate?.isReady == true
        owners.forEach { owner, component, transform, controller in
            var value = component.wrappedValue
            let root = value.resolveTarget(owner: owner, in: context.world, hasController: controller != nil, hasTransform: transform != nil)
            if physicsIsReady, let controller, let step = controller.resolvedStep, step.sequence != value.runtime.lastStep {
                value.runtime.lastStep = step.sequence
                if step.resetGeneration != value.runtime.resetGeneration {
                    value.runtime.resetMotion()
                    value.runtime.resetGeneration = step.resetGeneration
                }
                if root != nil, let transform,
                    let rotation = value.runtime.motion.advance(
                        velocity: step.velocity,
                        grounded: step.isGrounded,
                        deltaTime: step.deltaTime,
                        rotation: transform.rotation,
                        configuration: value.configuration
                    ) {
                    transform.rotation = rotation
                }
            }
            if component.wrappedValue.runtime != value.runtime { component.wrappedValue.runtime = value.runtime }
        }
    }
}

@PlainSystem(dependencies: [.after(ModelAnimationPlayback3DSystem.self), .before(SkeletalAnimation3DSystem.self)])
struct CharacterLocomotion3DPlaybackSystem {
    @Query<Entity, Ref<Locomotion>, Transform?, CharacterController3DComponent?> private var owners
    @Query<Model3DSource, Model3DSourceState, ModelAnimationPlayback3DComponent,
           PhysicsBody3DComponent, RelationshipComponent> private var bindingAccess
    @Query<Entity, Ref<ModelAnimation3DComponent>> private var models

    init(world _: World) {}

    func update(context: UpdateContext) {
        _ = bindingAccess
        var byModel: [Entity.ID: Ref<Locomotion>] = [:]
        owners.forEach { owner, component, transform, controller in
            var value = component.wrappedValue
            if let root = value.resolveTarget(owner: owner, in: context.world, hasController: controller != nil, hasTransform: transform != nil),
                value.runtime.motion.request != nil {
                byModel[root] = component
            }
            if component.wrappedValue.runtime != value.runtime { component.wrappedValue.runtime = value.runtime }
        }
        guard !byModel.isEmpty else {
            return
        }
        models.forEach { root, animation in
            guard let component = byModel[root.id] else {
                return
            }
            var runtime = component.wrappedValue.runtime
            var player = animation.wrappedValue.player
            if runtime.apply(to: &player, configuration: component.wrappedValue.configuration) {
                animation.wrappedValue.player = player
            }
            if component.wrappedValue.runtime != runtime { component.wrappedValue.runtime = runtime }
        }
    }
}
