import AdaAnimation
import AdaECS
import AdaScene
import AdaUtils
import Foundation
import Testing

// Minimal KeyframeAnimatable used only in tests; applies nothing (no world access needed).
private struct TestAnim: KeyframeAnimatable {
    var x: Float = 0
    func apply(to entityId: Entity.ID, in world: World) {}
}

@Suite(.serialized)
struct KeyframeAnimatorTests {

    @Test
    func playClipSetsRequestedClipAndIncrementsToken() {
        let a = KeyframeClip(name: "a", initialValues: TestAnim(), duration: 1, repeatMode: .once)
        let b = KeyframeClip(name: "b", initialValues: TestAnim(), duration: 1, repeatMode: .once)
        var animator = KeyframeAnimator(clips: [AnyAnimatorClip(a), AnyAnimatorClip(b)], initialClipName: "a")
        let tokenBefore = animator.runToken

        animator.playClip(by: "b")

        #expect(animator.requestedClipName == "b")
        #expect(animator.playbackState == .playing)
        #expect(animator.runToken == tokenBefore + 1)
    }

    @Test
    func stopTransitionsToStoppedAndIncrementsToken() {
        let clip = KeyframeClip(name: "idle", initialValues: TestAnim(), duration: 1, repeatMode: .once)
        var animator = KeyframeAnimator(clips: [AnyAnimatorClip(clip)], initialClipName: "idle")
        let tokenBefore = animator.runToken

        animator.stop()

        #expect(animator.playbackState == .stopped)
        #expect(animator.runToken == tokenBefore + 1)
    }

    @Test
    func builderInitSelectsFirstClipAsDefault() {
        var animator = KeyframeAnimator {
            KeyframeClip(name: "intro", initialValues: TestAnim(), duration: 0.5, repeatMode: .once)
            KeyframeClip(name: "loop", initialValues: TestAnim(), duration: 1, repeatMode: .loop())
        }
        #expect(animator.currentClipName == "intro")
        animator.playClip(by: "loop")
        #expect(animator.requestedClipName == "loop")
    }

    // MARK: - Event-based finish

    /// Shared sink to collect ``KeyframeAnimatorRunDidFinish`` events filtered
    /// by entity id (so events from other tests running in parallel cannot
    /// bleed in).
    private final class EventSink: @unchecked Sendable {
        let lock = NSLock()
        var events: [KeyframeAnimatorRunDidFinish] = []
        let entityID: Entity.ID
        var cancellable: (any Cancellable)?

        init(entityID: Entity.ID) {
            self.entityID = entityID
            self.cancellable = EventManager.default.subscribe(to: KeyframeAnimatorRunDidFinish.self) { [weak self] event in
                guard let self, event.entityID == self.entityID else { return }
                self.lock.lock()
                self.events.append(event)
                self.lock.unlock()
            }
        }

        deinit {
            cancellable?.cancel()
        }

        func snapshot() -> [KeyframeAnimatorRunDidFinish] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    @Test
    func applySystemEmitsFinishEventWhenClipEnds() async {
        let world = World()
        world.addSystem(KeyframeAnimationApplySystem.self, on: .update)

        // Duration small enough to finish inside the first clamped dt (~1/15s).
        let clip = KeyframeClip(name: "short", initialValues: TestAnim(), duration: 0.01, repeatMode: .once)
        let animator = KeyframeAnimator(clips: [AnyAnimatorClip(clip)], initialClipName: "short")
        let entity = world.spawn("Actor") { animator }

        let sink = EventSink(entityID: entity.id)
        let startToken = entity.components[KeyframeAnimator.self]!.runToken

        await world.runScheduler(.update)

        let events = sink.snapshot()
        #expect(events.count == 1)
        #expect(events.first?.runToken == startToken)
        #expect(entity.components[KeyframeAnimator.self]?.playbackState == .stopped)
    }

    @Test
    func externalPlayClipDuringRunEmitsFinishEventForPreviousToken() async {
        let world = World()
        world.addSystem(KeyframeAnimationApplySystem.self, on: .update)

        // Long clip so first tick doesn't finish it on its own.
        let loop = KeyframeClip(name: "loop", initialValues: TestAnim(), duration: 10, repeatMode: .loop())
        let once = KeyframeClip(name: "once", initialValues: TestAnim(), duration: 0.01, repeatMode: .once)
        let animator = KeyframeAnimator(
            clips: [AnyAnimatorClip(loop), AnyAnimatorClip(once)],
            initialClipName: "loop"
        )
        let entity = world.spawn("Actor") { animator }

        let sink = EventSink(entityID: entity.id)

        // First tick registers the initial token with the system.
        await world.runScheduler(.update)
        #expect(sink.snapshot().isEmpty)

        // Interrupt the run by requesting a different clip; apply system should
        // detect the token change on its next tick and emit a finish event for
        // the previous run.
        var anim = entity.components[KeyframeAnimator.self]!
        let interruptedToken = anim.runToken
        anim.playClip(by: "once")
        entity.components[KeyframeAnimator.self] = anim

        await world.runScheduler(.update)

        let events = sink.snapshot()
        #expect(events.contains(where: { $0.runToken == interruptedToken }))
    }
}
