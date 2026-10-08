//
//  KeyframeAnimationApplySystem.swift
//  AdaScene
//

import AdaAnimation
import AdaECS
import AdaUtils

/// Advances each ``KeyframeAnimator``'s playhead and applies the interpolated value
/// to the owner entity via ``KeyframeAnimatable/apply(to:in:)``.
///
/// Emits ``KeyframeAnimatorRunDidFinish`` on ``EventManager/default`` whenever a
/// specific run finishes — either because the clip ended naturally, or because
/// an external actor mutated ``KeyframeAnimator/runToken`` (via
/// ``KeyframeAnimator/playClip(by:)`` or ``KeyframeAnimator/stop()``). This lets
/// awaiters suspend without polling the ECS world from another actor.
@PlainSystem
public struct KeyframeAnimationApplySystem: Sendable {
    @Query<Entity, Ref<KeyframeAnimator>>
    private var animators

    @Res
    private var deltaTime: DeltaTime

    /// Last observed `runToken` per animated entity. Used to detect external
    /// interrupts (the user called `playClip`/`stop` between our ticks) so we
    /// can emit a finish event for the previous run.
    @Local
    private var lastSeenTokens: [Entity.ID: UInt64] = [:]

    public init(world _: World) {}

    public func update(context: UpdateContext) async {
        let world = context.world
        // Clamp large first-frame deltas that can arise from scheduler cold start.
        let dt = max(0, min(deltaTime.deltaTime, 1.0 / 15.0))

        var seenThisTick: Set<Entity.ID> = []
        seenThisTick.reserveCapacity(lastSeenTokens.count)

        animators.forEach { ownerEntity, animator in
            var anim = animator.wrappedValue
            let entityID = ownerEntity.id
            seenThisTick.insert(entityID)

            // Detect external interrupts: if the token moved while we weren't
            // looking, the previous run is effectively over — notify waiters.
            if let previousToken = lastSeenTokens[entityID], previousToken != anim.runToken {
                EventManager.default.send(
                    KeyframeAnimatorRunDidFinish(entityID: entityID, runToken: previousToken)
                )
            }

            guard anim.playbackState == .playing else {
                lastSeenTokens[entityID] = anim.runToken
                return
            }

            // Apply a pending clip-switch request.
            if let requested = anim.requestedClipName {
                if anim.clipsByName[requested] != nil {
                    anim.currentClipName = requested
                    anim.localTime = 0
                }
                anim.requestedClipName = nil
            }

            guard
                let clipName = anim.currentClipName,
                let clip = anim.clipsByName[clipName]
            else {
                let finishedToken = anim.runToken
                anim.playbackState = .stopped
                anim.runToken &+= 1
                animator.wrappedValue = anim
                lastSeenTokens[entityID] = anim.runToken
                EventManager.default.send(
                    KeyframeAnimatorRunDidFinish(entityID: entityID, runToken: finishedToken)
                )
                return
            }

            anim.localTime += TimeInterval(Double(dt) * anim.speed)

            let state = keyframePlaybackState(
                playhead: anim.localTime,
                duration: clip.duration,
                mode: clip.repeatMode
            )

            clip.applyAt(state.localTime, entityID, world)

            var finishedToken: UInt64?
            if state.isFinished {
                finishedToken = anim.runToken
                anim.playbackState = .stopped
                anim.runToken &+= 1
            }
            animator.wrappedValue = anim
            lastSeenTokens[entityID] = anim.runToken

            if let finishedToken {
                EventManager.default.send(
                    KeyframeAnimatorRunDidFinish(entityID: entityID, runToken: finishedToken)
                )
            }
        }

        // Drop tokens for entities that no longer carry an animator so the map
        // does not grow unbounded across the app's lifetime.
        if lastSeenTokens.count != seenThisTick.count {
            lastSeenTokens = lastSeenTokens.filter { seenThisTick.contains($0.key) }
        }
    }
}
