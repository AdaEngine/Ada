import Foundation
import Math

/// Instance-owned playback and pose buffers. The rig and clips can be shared by value.
public struct SkeletalAnimationPlayer: Sendable {
    /// Identifies this playback instance even when its pose generation restarts.
    public let instanceID = UUID()
    public let rig: SkeletalRig
    public let clips: [SkeletalAnimationClip]
    public private(set) var clipIndex: Int?
    public private(set) var time: Double = 0
    /// Changes whenever evaluated or interpolated pose matrices change.
    public private(set) var poseGeneration: UInt64 = 0
    public var speed: Double = 1
    public var isPlaying = false
    public var repeats = true
    public private(set) var poses: [SkeletalJointPose]
    public private(set) var localTransforms: [Transform3D]
    public private(set) var globalTransforms: [Transform3D]
    private var transitionSource: [SkeletalJointPose] = []
    private var transitionDuration: Double = 0
    private var transitionTime: Double = 0
    private var graphState: CompiledAnimationGraph?
    private var pendingGraphEvents: [AnimationGraphEvent] = []
    /// Occurrences omitted when a frame or undrained queue exceeds the 1,024-event budget.
    public private(set) var droppedGraphEventCount = 0
    public var graph: AnimationGraph? { graphState?.graph }

    public init(rig: SkeletalRig, clips: [SkeletalAnimationClip]) throws(SkeletalAnimationError) {
        guard
            clips.allSatisfy({ clip in
                clip.tracks.allSatisfy { rig.nodes.indices.contains($0.nodeIndex) && rig.nodes[$0.nodeIndex].restPose != nil }
            })
        else { throw .invalidTrack }
        self.rig = rig
        self.clips = clips
        self.poses = rig.nodes.map { $0.restPose ?? SkeletalJointPose() }
        self.localTransforms = rig.nodes.map(\.restMatrix)
        self.globalTransforms = Array(repeating: .identity, count: rig.nodes.count)
        evaluate()
    }

    /// Starts a named clip, optionally fading from the current pose.
    public mutating func play(_ name: String, transitionDuration: Double = 0.15) throws(SkeletalAnimationError) {
        try play(name, transitionDuration: transitionDuration, startTime: 0)
    }

    /// Starts at a clip-local time without cancelling the fade. Useful for matching walk/run phases.
    /// Non-finite start times are treated as zero; looping and clamping follow `repeats`.
    public mutating func play(_ name: String, transitionDuration: Double = 0.15, startTime: Double) throws(SkeletalAnimationError) {
        guard let index = clips.firstIndex(where: { $0.name == name }) else { throw .unknownClip(name) }
        graphState = nil
        pendingGraphEvents.removeAll(keepingCapacity: true)
        self.transitionSource = poses
        self.transitionDuration = transitionDuration.isFinite ? max(0, transitionDuration) : 0
        self.transitionTime = 0
        self.clipIndex = index
        self.time = startTime.isFinite ? startTime : 0
        self.isPlaying = true
        evaluate()
    }

    /// Seeks within the selected clip; a seek cancels a pending transition.
    public mutating func seek(to time: Double) {
        guard time.isFinite else {
            return
        }
        self.time = time
        pendingGraphEvents.removeAll(keepingCapacity: true)
        transitionDuration = 0
        evaluate()
    }

    public mutating func advance(by deltaTime: Double) { advance(by: deltaTime, evaluatePose: true) }

    /// Advances playback and transitions independently from the visual pose sampling rate.
    public mutating func advance(by deltaTime: Double, evaluatePose: Bool) {
        guard isPlaying, deltaTime.isFinite, deltaTime >= 0, speed.isFinite else {
            return
        }
        let nextTime = time + deltaTime * speed
        guard nextTime.isFinite else {
            return
        }
        let previousTime = time
        time = nextTime
        transitionTime += deltaTime
        if let graphState, !graphState.loops {
            time = min(max(time, 0), graphState.duration)
            if speed >= 0 && time >= graphState.duration || speed < 0 && time <= 0 {
                isPlaying = transitionTime < transitionDuration
            }
        } else if let clipIndex, !repeats {
            let duration = clips[clipIndex].duration
            if speed >= 0 && time >= duration || speed < 0 && time <= 0 {
                time = min(max(time, 0), duration)
                isPlaying = transitionTime < transitionDuration
            }
        }
        let graphTime = time
        let graphClips = clips
        let eventCapacity = 1_024 - pendingGraphEvents.count
        if let crossings = graphState?.events(from: previousTime, to: graphTime, clips: graphClips, capacity: eventCapacity) {
            pendingGraphEvents.append(contentsOf: crossings.events)
            droppedGraphEventCount += min(Int.max / 2 - droppedGraphEventCount, crossings.dropped)
        }
        if evaluatePose { evaluate() }
    }

    /// Installs a validated graph atomically. Invalid edits leave current playback unchanged.
    public mutating func play(_ graph: AnimationGraph, transitionDuration: Double = 0.15) throws(AnimationGraphError) {
        let compiled = try CompiledAnimationGraph(graph: graph, rig: rig, clips: clips)
        graphState = compiled
        clipIndex = nil
        transitionSource = poses
        self.transitionDuration = transitionDuration.isFinite ? max(0, transitionDuration) : 0
        transitionTime = 0
        time = 0
        isPlaying = true
        pendingGraphEvents.removeAll(keepingCapacity: true)
        droppedGraphEventCount = 0
        evaluate()
    }

    /// Changes a blend/layer weight without restarting clocks or allocating a new graph.
    public mutating func setGraphWeight(_ weight: Float, node: String, input: Int) throws(AnimationGraphError) {
        guard weight.isFinite, (0...1_000).contains(weight) else { throw .invalidWeight }
        guard let index = graphState?.graph.nodes.firstIndex(where: { $0.id == node }),
            graphState?.graph.nodes[index].inputs.indices.contains(input) == true else { throw .invalidNode(node) }
        graphState?.graph.nodes[index].inputs[input].weight = weight
        evaluate()
    }

    /// Drains gameplay markers once. Pause, seek and visual-only sampling never emit crossings.
    public mutating func drainGraphEvents() -> [AnimationGraphEvent] {
        let events = pendingGraphEvents
        pendingGraphEvents.removeAll(keepingCapacity: true)
        return events
    }

    /// Evaluates the current playback clock without advancing gameplay time.
    public mutating func sampleCurrentPose() { evaluate() }

    /// Interpolates visual poses; playback/transition clocks remain unchanged.
    public mutating func presentPose(from source: [SkeletalJointPose], to target: [SkeletalJointPose], amount: Float) {
        guard source.count == poses.count, target.count == poses.count else {
            return
        }
        let t = amount.isFinite ? min(max(amount, 0), 1) : 1
        for index in poses.indices {
            poses[index].translation = source[index].translation + (target[index].translation - source[index].translation) * t
            poses[index].scale = source[index].scale + (target[index].scale - source[index].scale) * t
            poses[index].rotation = slerpQuat(source[index].rotation, target[index].rotation, t: t)
        }
        rebuildTransforms()
    }

    private mutating func evaluate() {
        for index in rig.nodes.indices { poses[index] = rig.nodes[index].restPose ?? SkeletalJointPose() }
        if graphState != nil {
            let graphTime = time
            let graphClips = clips
            graphState?.evaluate(time: graphTime, clips: graphClips)
            if let root = graphState?.root {
                for index in poses.indices { poses[index] = graphState?.poses[root][index] ?? poses[index] }
            }
        } else if let clipIndex {
            let clip = clips[clipIndex]
            let remainder = clip.duration > 0 ? time.truncatingRemainder(dividingBy: clip.duration) : 0
            let localTime = repeats ? (remainder < 0 ? remainder + clip.duration : remainder) : min(max(time, 0), clip.duration)
            for track in clip.tracks {
                let value = track.sample(at: localTime)
                switch track.path {
                case .translation: poses[track.nodeIndex].translation = value.xyz
                case .rotation: poses[track.nodeIndex].rotation = Quat(x: value.x, y: value.y, z: value.z, w: value.w)
                case .scale: poses[track.nodeIndex].scale = value.xyz
                }
            }
        }
        if transitionDuration > 0 && transitionTime < transitionDuration {
            let amount = Float(transitionTime / transitionDuration)
            for index in poses.indices where rig.nodes[index].restPose != nil {
                let source = transitionSource[index]
                poses[index].translation = source.translation + (poses[index].translation - source.translation) * amount
                poses[index].scale = source.scale + (poses[index].scale - source.scale) * amount
                poses[index].rotation = slerpQuat(source.rotation, poses[index].rotation, t: amount)
            }
        } else {
            transitionSource.removeAll(keepingCapacity: true)
            transitionDuration = 0
        }
        rebuildTransforms()
    }

    private mutating func rebuildTransforms() {
        poseGeneration &+= 1
        for index in rig.evaluationOrder {
            let node = rig.nodes[index]
            localTransforms[index] = node.restPose == nil ? node.restMatrix : poses[index].matrix
            if let parent = node.parentIndex {
                globalTransforms[index] = globalTransforms[parent] * localTransforms[index]
            } else {
                globalTransforms[index] = localTransforms[index]
            }
        }
    }
}
