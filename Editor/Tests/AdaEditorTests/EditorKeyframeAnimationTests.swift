@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor keyframe animation")
struct EditorKeyframeAnimationTests {
    @Test("tracks sample linear, hold, and cubic curves")
    func trackSamplingUsesSelectedCurve() throws {
        let linear = EditorAnimationTrack(
            property: .positionX,
            keyframes: [
                EditorAnimationKeyframe(time: 0, value: 0, curveToNext: .linear),
                EditorAnimationKeyframe(time: 1, value: 10),
            ]
        )
        var hold = linear
        hold.keyframes[0].curveToNext = .hold
        var cubic = linear
        cubic.keyframes[0].curveToNext = .cubicInOut

        #expect(linear.value(at: 0.25) == 2.5)
        #expect(hold.value(at: 0.75) == 0)
        #expect(abs((try #require(cubic.value(at: 0.25))) - 1.5625) < 0.000_1)
    }

    @Test("animation clips round-trip in scene YAML and legacy scenes remain decodable")
    func animationClipsRoundTripThroughSceneYAML() throws {
        var model = EditorSceneModel.default(projectName: "Animation")
        let entityID = try #require(model.editor?.selectedEntity)
        let clip = model.addAnimationClip(targetEntityID: entityID, name: "Move")
        let track = try #require(model.animations?.first?.tracks.first)
        let addedKeyframe = model.addAnimationKeyframe(clipID: clip.id, trackID: track.id, time: 0.5)
        let keyframe = try #require(addedKeyframe)
        model.updateAnimationKeyframe(clipID: clip.id, trackID: track.id, keyframeID: keyframe.id, value: 12, curve: .cubicInOut)

        let decoded = try EditorSceneModel.decode(from: model.encodedYAML())
        let decodedClip = try #require(decoded.animations?.first)
        let decodedKeyframe = try #require(decodedClip.tracks.first?.keyframes.first { $0.id == keyframe.id })

        #expect(decodedClip.name == "Move")
        #expect(decodedKeyframe.value == 12)
        #expect(decodedKeyframe.curveToNext == .cubicInOut)

        let legacy = try EditorSceneModel.decode(
            from: """
                format: ada.scene
                schemaVersion: 1
                scene:
                  id: legacy
                  name: Legacy
                entities: []
                """
        )
        #expect(legacy.animations == nil)
    }

    @Test("scene loader installs runnable animator clips on their target entity")
    @MainActor
    func sceneLoaderInstallsRuntimeAnimator() throws {
        var model = EditorSceneModel.default(projectName: "RuntimeAnimation")
        let entityID = try #require(model.editor?.selectedEntity)
        let clip = model.addAnimationClip(targetEntityID: entityID, name: "Move")
        let track = try #require(model.animations?.first?.tracks.first)
        let firstKeyframe = try #require(track.keyframes.first)
        let lastKeyframe = try #require(track.keyframes.last)
        model.updateAnimationKeyframe(clipID: clip.id, trackID: track.id, keyframeID: firstKeyframe.id, value: 0)
        model.updateAnimationKeyframe(clipID: clip.id, trackID: track.id, keyframeID: lastKeyframe.id, value: 10)

        let world = World(name: "EditorAnimationRuntime")
        let loadResult = EditorSceneFileLoader.load(model: model, into: world)
        let runtimeEntityID = try #require(loadResult.entitiesByEditorID[entityID])
        let animator = try #require(world.get(KeyframeAnimator.self, from: runtimeEntityID))
        let runtimeClip = try #require(animator.clipsByName["Move"])

        #expect(animator.playbackState == .playing)
        runtimeClip.applyAt(0.5, runtimeEntityID, world)
        #expect(world.get(Transform.self, from: runtimeEntityID)?.position.x == 5)
        #expect(loadResult.warnings.isEmpty)
    }

    @Test("panel playback advances from the current playhead and stops deterministically")
    @MainActor
    func panelPlaybackState() {
        let panel = EditorAnimationPanelViewModel()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        panel.playhead = 0.25

        panel.togglePlayback(now: start, duration: 2)

        #expect(panel.displayedPlayhead(now: start.addingTimeInterval(0.5), duration: 2) == 0.75)
        panel.togglePlayback(now: start.addingTimeInterval(0.5), duration: 2)
        #expect(!panel.isPlaying)
        #expect(panel.playhead == 0.75)
    }

    @Test("rendered animator panel adds a keyframe through its toolbar")
    @MainActor
    func renderedPanelAddsKeyframe() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "EditorAnimationPanelTests"))
            RenderWorldPlugin().setup(in: app)
        }
        let viewModel = EditorViewModel()
        viewModel.addAnimationClip()
        viewModel.animationPanel.playhead = 0.5
        let container = UIContainerView(rootView: EditorAnimationPanel(viewModel: viewModel))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 240)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Animator.Panel"))
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Animator.Mode.curves"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Animator.AddKeyframe"))

        #expect(viewModel.selectedAnimationTrack?.keyframes.count == 3)
        #expect(viewModel.selectedAnimationKeyframe?.time == 0.5)
    }
}
