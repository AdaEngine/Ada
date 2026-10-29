@_spi(AdaEngine) import AdaEngine
@testable import AdaAudio
@_spi(Internal) @testable import AdaRender
@_spi(Internal) import AdaUI
import Foundation
import Math
import miniaudio
import Observation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Editor audio asset preview", .serialized)
struct EditorAudioAssetPreviewTests {
    init() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
    }

    @Test("Audio document controls play real WAV samples, pause, stop and stop again when the view disappears")
    func workbenchPlaybackAndTabLifetime() async throws {
        let fixture = try AudioFixture()
        defer { fixture.cleanup() }
        let previousServer = unsafe AudioServer.shared
        let model = EditorAudioPreviewModel()
        defer { model.stop() }
        let visibility = AudioPreviewVisibility()
        let container = UIContainerView(rootView: AudioPreviewTestHost(document: fixture.document, model: model, visibility: visibility).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 600)
        container.bounds.size = container.frame.size
        await refresh(container)
        #expect(model.controller == nil, "Opening an audio tab must not autoplay")

        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AudioPreview.Play"))
        try await waitUntil { model.state == .playing }
        let engine = try fixture.storage(model)
        #expect(try fixture.renderPeak(engine) > 0.05)
        #expect(unsafe AudioServer.shared === previousServer)
        #expect(unsafe ma_engine_get_device(engine.enginePtr) == nil)
        await refresh(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AudioPreview.Play"))
        #expect(model.state == .paused)
        #expect(try fixture.renderPeak(engine) == 0)
        await refresh(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AudioPreview.Play"))
        #expect(try fixture.renderPeak(engine) > 0.05)
        await refresh(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AudioPreview.Stop"))
        #expect(try fixture.renderPeak(engine) == 0)

        await refresh(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AudioPreview.Play"))
        try await waitUntil { model.state == .playing }
        let restartedEngine = try fixture.storage(model)
        #expect(try fixture.renderPeak(restartedEngine) > 0.05)
        visibility.isVisible = false
        await refresh(container)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AudioPreview")).isEmpty)
        #expect(model.state == .stopped)
        #expect(try fixture.renderPeak(restartedEngine) == 0)
    }

    @Test("Finished audio resets the controls; stopped or failed loads cannot start later")
    func completionCancellationAndInvalidFiles() async throws {
        let fixture = try AudioFixture()
        defer { fixture.cleanup() }
        let model = EditorAudioPreviewModel()
        model.volume = 0.25
        model.togglePlayback(path: fixture.url.path)
        try await waitUntil { model.state == .playing }
        let engine = try fixture.storage(model)
        let peak = try fixture.renderPeak(engine, frames: 48_000)
        #expect(peak > 0.01 && peak < 0.2)
        try await waitUntil { model.state == .stopped }

        model.togglePlayback(path: fixture.url.path)
        model.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.state == .stopped)
        #expect(model.controller == nil)

        let invalid = fixture.url.deletingLastPathComponent().appendingPathComponent("invalid.wav")
        try Data([1, 2, 3]).write(to: invalid)
        model.togglePlayback(path: invalid.path)
        try await waitUntil { model.state == .stopped }
        #expect(model.errorDetail != nil)
        model.togglePlayback(path: fixture.url.path)
        try await waitUntil { model.state == .playing }
        #expect(model.errorDetail == nil)
        #expect(try fixture.renderPeak(fixture.storage(model)) > 0.01)
        model.stop()
    }

    @Test("Opening a WAV in the workbench routes to listening controls and leaving its tab removes them")
    func workbenchRouting() async throws {
        let fixture = try AudioFixture()
        defer { fixture.cleanup() }
        let document = fixture.document
        let other = EditorAssetDocument(id: "other", title: "other.bin", relativePath: "other.bin", kind: .generic, fileExtension: "bin")
        let workbench = EditorWorkbenchViewModel(openDocuments: [.asset(document), .asset(other)], activeDocumentID: document.id)
        let container = UIContainerView(rootView: center(workbench).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 600)
        container.bounds.size = container.frame.size
        await refresh(container)
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AudioPreview.Play")).isEmpty)
        workbench.selectDocument(id: other.id)
        await refresh(container)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AudioPreview")).isEmpty)
    }

    private func refresh<Content: View>(_ container: UIContainerView<Content>) async {
        for _ in 0..<10 {
            await Task.yield()
            container.update(1 / 60)
            container.layoutIfNeeded()
        }
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws {
        for _ in 0..<200 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try condition())
    }

    private func center(_ workbench: EditorWorkbenchViewModel) -> EditorCenterWorkbench {
        EditorCenterWorkbench(
            viewModel: workbench, inspectorViewModel: EditorInspectorSidebarViewModel(), playModeState: .editing,
            scenePlayRuntime: nil, sceneResourceRootURL: nil, onPlayScene: nil, onStopScene: nil, onSceneEntitySelected: nil,
            onSourceHover: nil, onGoToDefinition: nil, onCompletionPosition: nil, onCompletionRequest: nil,
            onApplyCompletion: nil, onMoveCompletionSelection: nil, onAcceptCompletion: nil,
            onTextSelection: nil, onChatSelection: nil, sourceContextMenuItems: nil,
            onSelectDocument: nil, onRevealDocument: nil, onCopyDocumentPath: nil, onSelectPreview: nil,
            onRebuildPreview: nil, onHidePreview: nil, onShowPreviewBuildOutput: nil
        )
    }
}

@MainActor
extension EditorLocalizationTests {
    @Test("Listening controls fit in a narrow preview and keep their state when the language changes")
    func audioPreviewLocalizationAndLayout() async throws {
        _ = try EditorAudioAssetPreviewTests()
        let fixture = try AudioFixture()
        defer { fixture.cleanup() }
        let previousLanguage = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previousLanguage }
        let model = EditorAudioPreviewModel()
        let container = UIContainerView(rootView: EditorAudioAssetPreview(document: fixture.document, model: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 360, height: 480)
        container.bounds.size = container.frame.size
        for language in [EditorLanguage.english, .russian] {
            EditorLocalization.shared.preference = language
            for _ in 0..<10 {
                await Task.yield()
                container.update(1 / 60)
                container.layoutIfNeeded()
            }
            for control in ["Play", "Stop", "Volume"] {
                let node = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AudioPreview.\(control)"))
                #expect(node.absoluteFrame.minX >= 0 && node.absoluteFrame.maxX <= 360)
                #expect(node.absoluteFrame.minY >= 0 && node.absoluteFrame.maxY <= 480)
            }
            #expect(model.state == .stopped)
        }
        #expect(L10n.tr("Listen") == "Слушать")
    }
}

@Observable
@MainActor
private final class AudioPreviewVisibility {
    var isVisible = true
}

private struct AudioPreviewTestHost: View {
    let document: EditorAssetDocument
    let model: EditorAudioPreviewModel
    let visibility: AudioPreviewVisibility

    var body: some View {
        if visibility.isVisible {
            EditorAudioAssetPreview(document: document, model: model)
        } else {
            Text("Other document")
        }
    }
}

@MainActor
private struct AudioFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioPreview-\(UUID())/tone.wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var spec = SoundSpec()
        spec.peak = 0.5
        spec.voices = [SoundVoice(wave: .sine, frequency: 440, duration: 0.5)]
        try WAVWriter().encode(SoundSynth.render(spec)).write(to: url)
    }

    var document: EditorAssetDocument {
        EditorAssetDocument(id: url.path, title: "tone.wav", relativePath: "Assets/tone.wav", absolutePath: url.path, kind: .audio, fileExtension: "wav")
    }

    func storage(_ model: EditorAudioPreviewModel) throws -> MiniAudioStorage {
        let controller = try #require(model.controller)
        let sound = try #require(controller.sound as? MiniSound)
        return unsafe sound.engineOwner
    }

    func renderPeak(_ engine: MiniAudioStorage, frames: Int = 480) throws -> Float {
        var pcm = [Float](repeating: 0, count: frames * 2)
        var read: ma_uint64 = 0
        let result = unsafe pcm.withUnsafeMutableBufferPointer {
            ma_engine_read_pcm_frames(engine.enginePtr, $0.baseAddress, ma_uint64(frames), &read)
        }
        #expect(result == MA_SUCCESS && read <= ma_uint64(frames))
        return pcm.map(abs).max() ?? 0
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
