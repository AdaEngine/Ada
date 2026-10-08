//
//  KeyframeAnimator.swift
//  AdaScene
//

import AdaAnimation
import AdaECS
import AdaUtils

/// ECS component that plays ``KeyframeClip``s on the entity it is attached to.
///
/// Attach it to an entity whose components you want to animate:
/// ```swift
/// app.main.spawn("Hero") {
///     Sprite(texture: tex)
///     Transform()
///     KeyframeAnimator {
///         KeyframeClip(name: "idle", initialValues: HeroAnim(), duration: 2, repeatMode: .loop) {
///             KeyframeTrack(\.transform.position) {
///                 LinearKeyframe(Vector3(0, 25, 0), duration: 1)
///                 LinearKeyframe(Vector3(0,  0, 0), duration: 1)
///             }
///         }
///     }
/// }
/// ```
@Component
public struct KeyframeAnimator: @unchecked Sendable {
    public enum PlaybackState: Sendable, Hashable {
        case playing
        case stopped
    }

    // MARK: - State

    public var clipsByName: [String: AnyAnimatorClip]
    public var currentClipName: String?
    public var requestedClipName: String?
    public var playbackState: PlaybackState

    /// Current position along the active clip in seconds.
    public var localTime: TimeInterval

    /// Multiplier applied to the frame delta while playing.
    public var speed: Double

    /// Incremented whenever a run is interrupted, finished, or stopped — used by `waitUntilFinished`.
    public var runToken: UInt64

    // MARK: - Init (builder)

    /// Create an animator from a list of clips written with result-builder syntax.
    ///
    /// Clips are automatically type-erased from `KeyframeClip<Value>` to `AnyAnimatorClip`
    /// via the `@KeyframeAnimatorBuilder`.
    public init(
        speed: Double = 1,
        isPlaying: Bool = true,
        @KeyframeAnimatorBuilder _ build: () -> [AnyAnimatorClip]
    ) {
        let clips = build()
        var map: [String: AnyAnimatorClip] = [:]
        for clip in clips where !clip.name.isEmpty {
            map[clip.name] = clip
        }
        self.clipsByName = map
        self.currentClipName = clips.first?.name
        self.requestedClipName = nil
        self.playbackState = isPlaying ? .playing : .stopped
        self.localTime = 0
        self.speed = speed
        self.runToken = 0
    }

    // MARK: - Init (direct)

    public init(
        clips: [AnyAnimatorClip],
        initialClipName: String? = nil,
        speed _: Double = 1,
        isPlaying: Bool = true
    ) {
        var map: [String: AnyAnimatorClip] = [:]
        for clip in clips where !clip.name.isEmpty {
            map[clip.name] = clip
        }
        self.clipsByName = map
        self.currentClipName = initialClipName ?? clips.first?.name
        self.requestedClipName = nil
        self.playbackState = isPlaying ? .playing : .stopped
        self.localTime = 0
        self.speed = 1
        self.runToken = 0
    }

    // MARK: - Control

    /// Request playback of a named clip. Takes effect on the next ECS update tick.
    public mutating func playClip(by name: String) {
        requestedClipName = name
        playbackState = .playing
        runToken &+= 1
    }

    /// Stop playback immediately.
    public mutating func stop() {
        playbackState = .stopped
        runToken &+= 1
    }
}

// MARK: - Events

/// Event raised by ``KeyframeAnimationApplySystem`` when a specific animator run
/// completes (naturally or is interrupted by a new ``KeyframeAnimator/playClip(by:)``
/// or ``KeyframeAnimator/stop()`` call).
///
/// `runToken` identifies the run that finished — it matches the value of
/// ``KeyframeAnimator/runToken`` captured at the time the run was started.
public struct KeyframeAnimatorRunDidFinish: Event {
    public let entityID: Entity.ID
    public let runToken: UInt64

    public init(entityID: Entity.ID, runToken: UInt64) {
        self.entityID = entityID
        self.runToken = runToken
    }
}

// MARK: - Ref extensions (ECS live reference)

extension Ref where T == KeyframeAnimator {
    public mutating func playClip(by name: String) {
        wrappedValue.playClip(by: name)
    }

    public mutating func stopPlayback() {
        wrappedValue.stop()
    }

    /// Suspends the caller until the current playback run is interrupted, stopped, or naturally completed.
    ///
    /// Implementation note: this does not poll the ECS world. It subscribes to
    /// ``KeyframeAnimatorRunDidFinish`` on ``EventManager/default`` and awaits a
    /// matching event emitted by ``KeyframeAnimationApplySystem``.
    public mutating func waitUntilFinished(for entityID: Entity.ID) async {
        let token = wrappedValue.runToken
        guard wrappedValue.playbackState == .playing else {
            return
        }

        await KeyframeAnimatorWaitOnce.wait(entityID: entityID, runToken: token)
    }
}
