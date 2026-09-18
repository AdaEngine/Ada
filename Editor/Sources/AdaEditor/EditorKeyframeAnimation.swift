@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

enum EditorAnimationPanelMode: String, CaseIterable, Equatable, Sendable {
    case timeline
    case curves

    var title: String { rawValue.capitalized }
}

@Observable
@MainActor
final class EditorAnimationPanelViewModel {
    var mode: EditorAnimationPanelMode = .timeline
    var selectedClipID: String?
    var selectedTrackID: String?
    var selectedKeyframeID: String?
    var playhead: Double = 0
    var isPlaying = false
    var playbackStartedAt: Date?
    var playbackStartTime: Double = 0

    func selectClip(_ clip: EditorAnimationClip) {
        selectedClipID = clip.id
        selectedTrackID = clip.tracks.first?.id
        selectedKeyframeID = nil
        playhead = min(playhead, clip.duration)
        stopPlayback(at: playhead)
    }

    func selectTrack(_ track: EditorAnimationTrack) {
        selectedTrackID = track.id
        selectedKeyframeID = nil
    }

    func selectKeyframe(_ keyframe: EditorAnimationKeyframe) {
        selectedKeyframeID = keyframe.id
        playhead = keyframe.time
        stopPlayback(at: playhead)
    }

    func togglePlayback(now: Date = Date(), duration: Double) {
        if isPlaying {
            stopPlayback(at: displayedPlayhead(now: now, duration: duration))
        } else {
            playbackStartTime = playhead >= duration ? 0 : playhead
            playbackStartedAt = now
            isPlaying = true
        }
    }

    func stopPlayback(at time: Double) {
        playhead = max(0, time)
        playbackStartedAt = nil
        isPlaying = false
    }

    func displayedPlayhead(now: Date, duration: Double) -> Double {
        guard isPlaying, let playbackStartedAt else {
            return min(duration, max(0, playhead))
        }
        guard duration > 0 else {
            return 0
        }
        let elapsed = max(0, now.timeIntervalSince(playbackStartedAt))
        return (playbackStartTime + elapsed).truncatingRemainder(dividingBy: duration)
    }
}

enum EditorAnimationCurve: String, CaseIterable, Codable, Equatable, Sendable {
    case linear
    case hold
    case cubicInOut

    var title: String {
        switch self {
        case .linear: "Linear"
        case .hold: "Hold"
        case .cubicInOut: "Ease In Out"
        }
    }

    var runtimeValue: KeyframeCurveKind {
        switch self {
        case .linear: .linear
        case .hold: .hold
        case .cubicInOut: .cubicInOut
        }
    }
}

enum EditorAnimationRepeatMode: String, CaseIterable, Codable, Equatable, Sendable {
    case once
    case loop
    case pingPong

    var title: String {
        switch self {
        case .once: "Once"
        case .loop: "Loop"
        case .pingPong: "Ping Pong"
        }
    }

    var runtimeValue: KeyframeRepeatMode {
        switch self {
        case .once: .once
        case .loop: .loop()
        case .pingPong: .pingPong
        }
    }
}

enum EditorAnimationProperty: String, CaseIterable, Codable, Equatable, Sendable {
    case positionX = "transform.position.x"
    case positionY = "transform.position.y"
    case positionZ = "transform.position.z"
    case scaleX = "transform.scale.x"
    case scaleY = "transform.scale.y"
    case scaleZ = "transform.scale.z"

    var title: String {
        switch self {
        case .positionX: "Position X"
        case .positionY: "Position Y"
        case .positionZ: "Position Z"
        case .scaleX: "Scale X"
        case .scaleY: "Scale Y"
        case .scaleZ: "Scale Z"
        }
    }
}

struct EditorAnimationKeyframe: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var time: Double
    var value: Double
    var curveToNext: EditorAnimationCurve

    init(
        id: String = UUID().uuidString,
        time: Double,
        value: Double,
        curveToNext: EditorAnimationCurve = .linear
    ) {
        self.id = id
        self.time = max(0, time)
        self.value = value
        self.curveToNext = curveToNext
    }
}

struct EditorAnimationTrack: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var property: EditorAnimationProperty
    var keyframes: [EditorAnimationKeyframe]

    init(
        id: String = UUID().uuidString,
        property: EditorAnimationProperty,
        keyframes: [EditorAnimationKeyframe] = []
    ) {
        self.id = id
        self.property = property
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    func value(at time: Double) -> Double? {
        let keyframes = keyframes.sorted { $0.time < $1.time }
        guard let first = keyframes.first else {
            return nil
        }
        guard keyframes.count > 1 else {
            return first.value
        }
        guard time > first.time else {
            return first.value
        }
        guard let rightIndex = keyframes.firstIndex(where: { $0.time > time }) else {
            return keyframes.last?.value
        }

        let left = keyframes[rightIndex - 1]
        let right = keyframes[rightIndex]
        let duration = right.time - left.time
        guard duration > 0 else {
            return left.value
        }
        var progress = min(1, max(0, (time - left.time) / duration))
        switch left.curveToNext {
        case .linear:
            break
        case .hold:
            progress = 0
        case .cubicInOut:
            progress = progress * progress * (3 - 2 * progress)
        }
        return left.value + (right.value - left.value) * progress
    }
}

struct EditorAnimationClip: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var targetEntityID: String
    var duration: Double
    var repeatMode: EditorAnimationRepeatMode
    var tracks: [EditorAnimationTrack]

    init(
        id: String = UUID().uuidString,
        name: String,
        targetEntityID: String,
        duration: Double = 1,
        repeatMode: EditorAnimationRepeatMode = .once,
        tracks: [EditorAnimationTrack] = []
    ) {
        self.id = id
        self.name = name
        self.targetEntityID = targetEntityID
        self.duration = max(0.01, duration)
        self.repeatMode = repeatMode
        self.tracks = tracks
    }
}

extension EditorSceneModel {
    @discardableResult
    mutating func addAnimationClip(targetEntityID: String, name: String? = nil) -> EditorAnimationClip {
        let baseName = name ?? "Animation"
        let existingNames = Set((animations ?? []).map(\.name))
        var resolvedName = baseName
        var suffix = 2
        while existingNames.contains(resolvedName) {
            resolvedName = "\(baseName) \(suffix)"
            suffix += 1
        }

        let initialValue = animationValue(for: .positionX, entityID: targetEntityID) ?? 0
        let clip = EditorAnimationClip(
            name: resolvedName,
            targetEntityID: targetEntityID,
            tracks: [
                EditorAnimationTrack(
                    property: .positionX,
                    keyframes: [
                        EditorAnimationKeyframe(time: 0, value: initialValue),
                        EditorAnimationKeyframe(time: 1, value: initialValue),
                    ]
                )
            ]
        )
        animations = (animations ?? []) + [clip]
        return clip
    }

    mutating func removeAnimationClip(id clipID: String) {
        animations?.removeAll { $0.id == clipID }
        if animations?.isEmpty == true {
            animations = nil
        }
    }

    mutating func addAnimationTrack(property: EditorAnimationProperty, to clipID: String) -> EditorAnimationTrack? {
        guard
            var clips = animations,
            let clipIndex = clips.firstIndex(where: { $0.id == clipID }),
            !clips[clipIndex].tracks.contains(where: { $0.property == property })
        else {
            return nil
        }
        let value = animationValue(for: property, entityID: clips[clipIndex].targetEntityID) ?? property.defaultValue
        let track = EditorAnimationTrack(
            property: property,
            keyframes: [
                EditorAnimationKeyframe(time: 0, value: value),
                EditorAnimationKeyframe(time: clips[clipIndex].duration, value: value),
            ]
        )
        clips[clipIndex].tracks.append(track)
        animations = clips
        return track
    }

    mutating func removeAnimationTrack(id trackID: String, from clipID: String) {
        guard
            var clips = animations,
            let clipIndex = clips.firstIndex(where: { $0.id == clipID })
        else {
            return
        }
        clips[clipIndex].tracks.removeAll { $0.id == trackID }
        animations = clips
    }

    @discardableResult
    mutating func addAnimationKeyframe(clipID: String, trackID: String, time: Double) -> EditorAnimationKeyframe? {
        guard
            var clips = animations,
            let clipIndex = clips.firstIndex(where: { $0.id == clipID }),
            let trackIndex = clips[clipIndex].tracks.firstIndex(where: { $0.id == trackID })
        else {
            return nil
        }
        let clampedTime = min(clips[clipIndex].duration, max(0, time))
        let value =
            clips[clipIndex].tracks[trackIndex].value(at: clampedTime)
            ?? animationValue(for: clips[clipIndex].tracks[trackIndex].property, entityID: clips[clipIndex].targetEntityID)
            ?? clips[clipIndex].tracks[trackIndex].property.defaultValue
        let keyframe = EditorAnimationKeyframe(time: clampedTime, value: value)
        clips[clipIndex].tracks[trackIndex].keyframes.removeAll { abs($0.time - clampedTime) < 0.000_1 }
        clips[clipIndex].tracks[trackIndex].keyframes.append(keyframe)
        clips[clipIndex].tracks[trackIndex].keyframes.sort { $0.time < $1.time }
        animations = clips
        return keyframe
    }

    mutating func removeAnimationKeyframe(clipID: String, trackID: String, keyframeID: String) {
        guard
            var clips = animations,
            let clipIndex = clips.firstIndex(where: { $0.id == clipID }),
            let trackIndex = clips[clipIndex].tracks.firstIndex(where: { $0.id == trackID })
        else {
            return
        }
        clips[clipIndex].tracks[trackIndex].keyframes.removeAll { $0.id == keyframeID }
        animations = clips
    }

    mutating func updateAnimationKeyframe(
        clipID: String,
        trackID: String,
        keyframeID: String,
        time: Double? = nil,
        value: Double? = nil,
        curve: EditorAnimationCurve? = nil
    ) {
        guard
            var clips = animations,
            let clipIndex = clips.firstIndex(where: { $0.id == clipID }),
            let trackIndex = clips[clipIndex].tracks.firstIndex(where: { $0.id == trackID }),
            let keyframeIndex = clips[clipIndex].tracks[trackIndex].keyframes.firstIndex(where: { $0.id == keyframeID })
        else {
            return
        }
        if let time {
            clips[clipIndex].tracks[trackIndex].keyframes[keyframeIndex].time = min(clips[clipIndex].duration, max(0, time))
        }
        if let value {
            clips[clipIndex].tracks[trackIndex].keyframes[keyframeIndex].value = value
        }
        if let curve {
            clips[clipIndex].tracks[trackIndex].keyframes[keyframeIndex].curveToNext = curve
        }
        clips[clipIndex].tracks[trackIndex].keyframes.sort { $0.time < $1.time }
        animations = clips
    }

    mutating func updateAnimationClip(
        id clipID: String,
        name: String? = nil,
        duration: Double? = nil,
        repeatMode: EditorAnimationRepeatMode? = nil
    ) {
        guard
            var clips = animations,
            let clipIndex = clips.firstIndex(where: { $0.id == clipID })
        else {
            return
        }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                clips[clipIndex].name = trimmed
            }
        }
        if let duration {
            clips[clipIndex].duration = max(0.01, duration)
            for trackIndex in clips[clipIndex].tracks.indices {
                for keyframeIndex in clips[clipIndex].tracks[trackIndex].keyframes.indices {
                    clips[clipIndex].tracks[trackIndex].keyframes[keyframeIndex].time = min(
                        clips[clipIndex].tracks[trackIndex].keyframes[keyframeIndex].time,
                        clips[clipIndex].duration
                    )
                }
            }
        }
        if let repeatMode {
            clips[clipIndex].repeatMode = repeatMode
        }
        animations = clips
    }

    func animationValue(for property: EditorAnimationProperty, entityID: String) -> Double? {
        guard let transform = entities.first(where: { $0.id == entityID })?.components[EditorBuiltInComponentType.transform] else {
            return nil
        }
        switch property {
        case .positionX: return transform.vectorValue(key: "position", index: 0)
        case .positionY: return transform.vectorValue(key: "position", index: 1)
        case .positionZ: return transform.vectorValue(key: "position", index: 2)
        case .scaleX: return transform.vectorValue(key: "scale", index: 0)
        case .scaleY: return transform.vectorValue(key: "scale", index: 1)
        case .scaleZ: return transform.vectorValue(key: "scale", index: 2)
        }
    }
}

extension EditorAnimationProperty {
    var defaultValue: Double {
        switch self {
        case .positionX,
            .positionY,
            .positionZ:
            0
        case .scaleX,
            .scaleY,
            .scaleZ:
            1
        }
    }
}

extension EditorComponentPayload {
    func vectorValue(key: String, index: Int) -> Double? {
        guard case let .array(values)? = self[key], values.indices.contains(index) else {
            return nil
        }
        return values[index].doubleValue
    }
}

struct EditorTransformAnimationValues: KeyframeAnimatable, Sendable {
    var transform: Transform

    func apply(to entityId: Entity.ID, in world: World) {
        world.insert(transform, for: entityId)
    }
}

extension EditorAnimationClip {
    func makeRuntimeClip(initialTransform: Transform) -> AnyAnimatorClip {
        let initialValues = EditorTransformAnimationValues(transform: initialTransform)
        let runtimeTracks = tracks.compactMap { $0.makeRuntimeTrack() }
        let clip: KeyframeClip<EditorTransformAnimationValues> = KeyframeClip(
            name: name,
            initialValues: initialValues,
            duration: Float(duration),
            repeatMode: repeatMode.runtimeValue,
            tracks: runtimeTracks
        )
        return AnyAnimatorClip(clip)
    }
}

extension EditorAnimationTrack {
    func makeRuntimeTrack() -> AnyKeyframeTrack<EditorTransformAnimationValues>? {
        let frames: [(time: Float, value: Float, curveToNext: KeyframeCurveKind)] = keyframes.map {
            (time: Float($0.time), value: Float($0.value), curveToNext: $0.curveToNext.runtimeValue)
        }
        guard !frames.isEmpty else {
            return nil
        }
        let serialized = keyframes.map {
            SerializedKeyframe(time: $0.time, value: [Float($0.value)], curveToNext: $0.curveToNext.runtimeValue)
        }
        return AnyKeyframeTrack(
            identifier: property.rawValue,
            serializedKeyframes: serialized,
            applyFn: { values, time in
                guard let value = sampleVectorArithmetic(keyframes: frames, localTime: time) else {
                    return
                }
                switch property {
                case .positionX: values.transform.position.x = value
                case .positionY: values.transform.position.y = value
                case .positionZ: values.transform.position.z = value
                case .scaleX: values.transform.scale.x = value
                case .scaleY: values.transform.scale.y = value
                case .scaleZ: values.transform.scale.z = value
                }
            }
        )
    }
}
