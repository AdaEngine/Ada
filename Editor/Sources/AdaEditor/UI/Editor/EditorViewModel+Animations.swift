@_spi(AdaEngine) import AdaEngine

extension EditorViewModel {
    var activeAnimationClips: [EditorAnimationClip] {
        workbench.activeSceneDocument?.sceneModel?.animations ?? []
    }

    var selectedAnimationClip: EditorAnimationClip? {
        let clips = activeAnimationClips
        return clips.first { $0.id == animationPanel.selectedClipID } ?? clips.first
    }

    var selectedAnimationTrack: EditorAnimationTrack? {
        guard let clip = selectedAnimationClip else {
            return nil
        }
        return clip.tracks.first { $0.id == animationPanel.selectedTrackID } ?? clip.tracks.first
    }

    var selectedAnimationKeyframe: EditorAnimationKeyframe? {
        guard let track = selectedAnimationTrack else {
            return nil
        }
        return track.keyframes.first { $0.id == animationPanel.selectedKeyframeID }
    }

    func addAnimationClip() {
        guard
            let document = workbench.activeSceneDocument,
            let targetEntityID = document.sceneModel?.editor?.selectedEntity ?? document.sceneModel?.entities.first?.id
        else {
            return
        }
        var addedClip: EditorAnimationClip?
        workbench.updateSceneModelDocument(id: document.id, status: "Animation clip added") { model in
            addedClip = model.addAnimationClip(targetEntityID: targetEntityID)
        }
        if let addedClip {
            animationPanel.selectClip(addedClip)
        }
    }

    func removeSelectedAnimationClip() {
        guard let document = workbench.activeSceneDocument, let clip = selectedAnimationClip else {
            return
        }
        workbench.updateSceneModelDocument(id: document.id, status: "Animation clip removed") { model in
            model.removeAnimationClip(id: clip.id)
        }
        animationPanel.selectedClipID = activeAnimationClips.first?.id
        animationPanel.selectedTrackID = activeAnimationClips.first?.tracks.first?.id
        animationPanel.selectedKeyframeID = nil
    }

    func addAnimationTrack(_ property: EditorAnimationProperty) {
        guard let document = workbench.activeSceneDocument, let clip = selectedAnimationClip else {
            return
        }
        var addedTrack: EditorAnimationTrack?
        workbench.updateSceneModelDocument(id: document.id, status: "Animation track added") { model in
            addedTrack = model.addAnimationTrack(property: property, to: clip.id)
        }
        if let addedTrack {
            animationPanel.selectTrack(addedTrack)
        }
    }

    func removeSelectedAnimationTrack() {
        guard
            let document = workbench.activeSceneDocument,
            let clip = selectedAnimationClip,
            let track = selectedAnimationTrack
        else {
            return
        }
        workbench.updateSceneModelDocument(id: document.id, status: "Animation track removed") { model in
            model.removeAnimationTrack(id: track.id, from: clip.id)
        }
        animationPanel.selectedTrackID = selectedAnimationClip?.tracks.first?.id
        animationPanel.selectedKeyframeID = nil
    }

    func addAnimationKeyframe() {
        guard
            let document = workbench.activeSceneDocument,
            let clip = selectedAnimationClip,
            let track = selectedAnimationTrack
        else {
            return
        }
        var addedKeyframe: EditorAnimationKeyframe?
        workbench.updateSceneModelDocument(id: document.id, status: "Animation keyframe added") { model in
            addedKeyframe = model.addAnimationKeyframe(
                clipID: clip.id,
                trackID: track.id,
                time: animationPanel.playhead
            )
        }
        if let addedKeyframe {
            animationPanel.selectKeyframe(addedKeyframe)
        }
    }

    func removeSelectedAnimationKeyframe() {
        guard
            let document = workbench.activeSceneDocument,
            let clip = selectedAnimationClip,
            let track = selectedAnimationTrack,
            let keyframe = selectedAnimationKeyframe
        else {
            return
        }
        workbench.updateSceneModelDocument(id: document.id, status: "Animation keyframe removed") { model in
            model.removeAnimationKeyframe(clipID: clip.id, trackID: track.id, keyframeID: keyframe.id)
        }
        animationPanel.selectedKeyframeID = nil
    }

    func updateSelectedAnimationKeyframe(time: Double? = nil, value: Double? = nil, curve: EditorAnimationCurve? = nil) {
        guard
            let document = workbench.activeSceneDocument,
            let clip = selectedAnimationClip,
            let track = selectedAnimationTrack,
            let keyframe = selectedAnimationKeyframe
        else {
            return
        }
        workbench.updateSceneModelDocument(id: document.id, status: "Animation keyframe edited") { model in
            model.updateAnimationKeyframe(
                clipID: clip.id,
                trackID: track.id,
                keyframeID: keyframe.id,
                time: time,
                value: value,
                curve: curve
            )
        }
        if let time {
            animationPanel.playhead = min(clip.duration, max(0, time))
        }
    }

    func updateSelectedAnimationClip(name: String? = nil, duration: Double? = nil, repeatMode: EditorAnimationRepeatMode? = nil) {
        guard let document = workbench.activeSceneDocument, let clip = selectedAnimationClip else {
            return
        }
        workbench.updateSceneModelDocument(id: document.id, status: "Animation clip edited") { model in
            model.updateAnimationClip(id: clip.id, name: name, duration: duration, repeatMode: repeatMode)
        }
        if let duration {
            animationPanel.playhead = min(max(0, duration), animationPanel.playhead)
        }
    }
}
