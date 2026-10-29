import AdaEngine
import Math

/// An asset-free take that exercises the same renderer and mixer used by games.
@main
struct MovieMakerDemo {
    @MainActor
    static func main() async throws {
        let configuration = try MovieRecordingConfiguration.commandLine() ?? MovieRecordingConfiguration(
            outputURL: URL(fileURLWithPath: "Movies/demo.png"),
            width: 640,
            height: 360,
            frameCount: 180
        )
        let maker = MovieMaker()
        let scene = MovieDemoScene(configuration: configuration)
        defer { scene.music?.stop() }
        let recording = try await maker.record(configuration: configuration, make: { app in
            scene.configure(app)
        }, update: { world, frame in
            try scene.update(world: world, frame: frame)
        }, progress: { count in
            if count % configuration.framesPerSecond == 0 { print("Recorded \(count) frames") }
        })
        print("Saved \(recording.frameCount) frames (\(recording.duration) seconds) to \(configuration.outputURL.deletingLastPathComponent().path)")
    }
}

@MainActor
private final class MovieDemoScene {
    let configuration: MovieRecordingConfiguration
    var sprites: [Entity] = []
    var music: AudioPlaybackController?

    init(configuration: MovieRecordingConfiguration) { self.configuration = configuration }

    func configure(_ app: AppWorlds) {
        app.addPlugin(TransformPlugin())
            .addPlugin(RenderWorldPlugin())
            .addPlugin(CameraPlugin())
            .addPlugin(VisibilityPlugin())
            .addPlugin(Core2DPlugin())
            .addPlugin(SpritePlugin())
            .addPlugin(AudioPlugin())
        var camera = Camera()
        camera.backgroundColor = Color(red: 0.025, green: 0.035, blue: 0.08)
        app.spawn("TrailerCamera", bundle: Camera2D(camera: camera))
    }

    func update(world: World, frame: MovieFrame) throws {
        if sprites.isEmpty {
            for index in 0..<9 {
                let hue = Float(index) / 8
                let color = Color(red: 0.25 + hue * 0.7, green: 0.85 - hue * 0.4, blue: 1 - hue * 0.35)
                sprites.append(world.spawn("Light \(index)") {
                    Sprite(tintColor: color, size: [32, 32])
                    Transform()
                })
            }
            var spec = SoundSpec()
            spec.peak = 0.15
            spec.voices = [SoundVoice(wave: .sine, frequency: 220, duration: 1)]
            let resource = try AudioResource.create(from: WAVWriter().encode(SoundSynth.render(spec)))
            music = AudioServer.shared.prepareAudio(resource).setLoop(true)
            music?.play()
        }
        let time = Float(frame.time)
        for (index, entity) in sprites.enumerated() {
            let phase = time * 1.4 + Float(index) * .pi * 2 / 9
            let x = Math.cos(phase) * Float(configuration.width) * 0.32
            let y = Math.sin(phase * 2) * Float(configuration.height) * 0.28
            entity.components += Transform(rotation: Quat(axis: [0, 0, 1], angle: phase), position: [x, y, 0])
        }
    }
}
