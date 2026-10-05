import AdaAnimation
import AdaCorePipelines
import Math

/// Visual animation sampling by projected size. Gameplay/root transforms keep their own cadence.
/// Full-size models use every render frame; smaller visible models interpolate between samples.
public struct AnimationLOD3DSettings: Sendable {
    public var center: Vector3 = .zero
    public var radius: Float
    public var screenThresholds: [Float]
    /// Samples per second per level; zero means every render frame.
    public var sampleRates: [Float]
    public var offscreenRate: Float
    public var hysteresis: Float

    public init(radius: Float = 1.5, screenThresholds: [Float] = [0.15, 0.04], sampleRates: [Float] = [0, 30, 12], offscreenRate: Float = 8, hysteresis: Float = 0.15) {
        self.radius = radius
        self.screenThresholds = screenThresholds
        self.sampleRates = sampleRates
        self.offscreenRate = offscreenRate
        self.hysteresis = hysteresis
    }
}

struct AnimationLOD3DObserver {
    var view: Transform3D
    var projection: Transform3D
    var frustum: MeshVisibilityFrustum3D
}

struct AnimationLOD3DState: Sendable {
    var level: Int?
    var elapsed: Double = 0
    var interval: Double = 0
    var generation: UInt64?
    var source: [SkeletalJointPose] = []
    var target: [SkeletalJointPose] = []

    mutating func advance(player: inout SkeletalAnimationPlayer, delta: Double, settings: AnimationLOD3DSettings, transform: Transform3D, observers: [AnimationLOD3DObserver]) {
        let radius = settings.radius.isFinite ? max(0.01, settings.radius) : 1.5
        let scale = max(transform.x.xyz.length, max(transform.y.xyz.length, transform.z.xyz.length))
        let bounds = AABB(center: (transform * Vector4(settings.center, 1)).xyz, halfExtents: Vector3(radius * scale, radius * scale, radius * scale))
        var significance: Float = 0
        var visible = false
        for observer in observers where observer.frustum.intersects(bounds) {
            visible = true
            significance = max(significance, MeshVisibility3DMath.projectedDiameter(bounds, view: observer.view, projection: observer.projection))
        }
        let nextLevel = MeshVisibility3DMath.selectLOD(
            size: significance,
            thresholds: settings.screenThresholds,
            levels: settings.sampleRates.count,
            previous: level,
            hysteresis: settings.hysteresis
        )
        let rate = visible && settings.sampleRates.indices.contains(nextLevel) ? settings.sampleRates[nextLevel] : settings.offscreenRate
        let nextInterval = visible && rate == 0 ? 0 : 1 / Double(rate.isFinite ? min(max(rate, 1), 120) : 12)
        let externalChange = generation != player.poseGeneration
        let wasPlaying = player.isPlaying
        let dt = delta.isFinite ? max(0, delta) : 0
        // When rendering is already below the selected sampling rate, interpolation
        // adds cost and delay without skipping any evaluations. Present the current pose.
        if visible, nextInterval > 0, dt >= nextInterval {
            player.advance(by: dt)
            level = nextLevel; interval = nextInterval; elapsed = 0
            source = player.poses; target = player.poses; generation = player.poseGeneration
            return
        }
        player.advance(by: dt, evaluatePose: nextInterval == 0)
        elapsed += dt
        let immediate = externalChange || level != nextLevel || interval != nextInterval || wasPlaying && !player.isPlaying
        level = nextLevel
        interval = nextInterval
        if nextInterval == 0 {
            source.removeAll(keepingCapacity: true)
            target.removeAll(keepingCapacity: true)
            elapsed = 0
        } else {
            if immediate || player.isPlaying && elapsed >= nextInterval {
                source = target.isEmpty ? player.poses : target
                player.sampleCurrentPose()
                target = player.poses
                if immediate {
                    source = target
                    elapsed = 0
                } else {
                    elapsed.formTruncatingRemainder(dividingBy: nextInterval)
                }
            }
            if visible, source != target, source.count == player.poses.count, target.count == player.poses.count {
                player.presentPose(from: source, to: target, amount: Float(elapsed / nextInterval))
            }
        }
        generation = player.poseGeneration
    }
}
