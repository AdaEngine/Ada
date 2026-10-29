import AdaApp
import AdaAssets
@testable import AdaAudio
import AdaECS
@testable import AdaRender
import miniaudio
import Testing

@MainActor
@Suite("Headless audio", .serialized)
struct HeadlessAudioTests {
    @Test("Headless rendering keeps audio resources usable without a playback device")
    func headlessPluginDoesNotOpenPlaybackDevice() throws {
        let previousBackend = unsafe RenderEngine.configurations.preferredBackend
        let previousServer = unsafe AudioServer.shared
        defer {
            unsafe RenderEngine.configurations.preferredBackend = previousBackend
            unsafe AudioServer.shared = previousServer
        }

        unsafe RenderEngine.configurations.preferredBackend = .headless
        try RenderEngine.setupRenderEngine()
        let renderer = unsafe try #require(RenderEngine.shared)
        try #require(renderer.type == .headless)

        // A later preference change must not make an already headless process audible.
        unsafe RenderEngine.configurations.preferredBackend = .webgpu
        let app = AppWorlds(main: World())
        let plugin = AudioPlugin(masterVolume: 0.7)
        plugin.setup(in: app)
        defer { plugin.destroy(for: app) }

        let server = try #require(app.getResource(AudioServer.self))
        let engine = try #require(server.engine as? MiniAudioEngine)
        #expect(unsafe ma_engine_get_device(engine.engine.enginePtr) == nil)
        #expect(server.masterVolume == 0.7)

        var spec = SoundSpec()
        spec.voices = [SoundVoice(wave: .sine, frequency: 440, duration: 0.1)]
        let resource = try AudioResource.create(from: WAVWriter().encode(SoundSynth.render(spec)))
        let controller = server.prepareAudio(resource).setLoop(true)
        controller.play()
        #expect(controller.isPlaying)
        try server.stop()
        try server.start()
        #expect(unsafe ma_engine_get_device(engine.engine.enginePtr) == nil)
        controller.stop()
        #expect(!controller.isPlaying)
    }
}
