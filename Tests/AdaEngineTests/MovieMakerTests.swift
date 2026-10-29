import AdaAssets
import AdaAudio
import AdaCorePipelines
import AdaECS
@testable import AdaEngine
@_spi(Internal) import AdaRender
import AdaScene
import AdaTransform
import Foundation
import Testing

extension Render3DGPUTests {
    @MainActor
    @Suite("Movie Maker", .serialized)
    struct MovieMakerTests {
        private func directory() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("AdaMovie-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        @Test func parsesCommandLineAndResolvesProjectRelativePath() throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let config = try #require(try MovieRecordingConfiguration.commandLine([
                "--write-movie", "Movies/take.png", "--fixed-fps", "30", "--resolution", "1280x720",
                "--quit-after", "90", "--movie-warmup", "12", "--movie-no-audio"
            ], relativeTo: root))
            #expect(config.outputURL == root.appendingPathComponent("Movies/take.png"))
            #expect(config.framesPerSecond == 30 && config.frameCount == 90)
            #expect(config.width == 1280 && config.height == 720)
            #expect(config.warmupFrameCount == 12 && !config.includesAudio)
            #expect(try MovieRecordingConfiguration.commandLine(["--fixed-fps", "30"]) == nil)
        }

        @Test(arguments: [
            ["--write-movie"], ["--write-movie", "a.mp4"],
            ["--write-movie", "a.png", "--fixed-fps", "0"],
            ["--write-movie", "a.png", "--fixed-fps", "59"],
            ["--write-movie", "a.png", "--resolution", "0x720"],
            ["--write-movie", "a.png", "--resolution", "1280xx720"],
            ["--write-movie", "a.png", "--quit-after", "-1"],
            ["--write-movie", "a.png", "--quit-after", "9223372036854775807"],
            ["--write-movie", "a.png", "--movie-warmup", "-1"],
            ["--write-movie", "a.png", "--fixed-fps", "30", "--fixed-fps", "60"]
        ])
        func rejectsInvalidCommandLines(arguments: [String]) {
            #expect(throws: MovieMakerError.self) { try MovieRecordingConfiguration.commandLine(arguments) }
        }

        @Test func writesLosslessFramesAndSynchronizedWAVWithoutOverwriting() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let config = MovieRecordingConfiguration(outputURL: root.appendingPathComponent("clip.png"), framesPerSecond: 30, width: 2, height: 1, frameCount: 2)
            let writer = try MovieSequenceWriter(configuration: config)
            let samples = [Float](repeating: 0.25, count: 3200)
            let image = Image(width: 2, height: 1, data: Data([0, 0, 255, 255, 255, 0, 0, 128]), format: .bgra8)
            try await writer.append(image: image, samples: samples)
            // A take is playable even before it has been finalized.
            let partialAudio = try WAVReader().decode(Data(contentsOf: root.appendingPathComponent("clip.wav")))
            #expect(partialAudio.frameCount == 1600)
            try await writer.append(image: image, samples: samples)
            let result = try await writer.finish(status: .completed)
            let audio = try WAVReader().decode(Data(contentsOf: root.appendingPathComponent("clip.wav")))
            #expect(result.frameCount == 2 && result.duration == 2.0 / 30)
            #expect(audio.frameCount == 3200 && audio.channels == 2 && audio.sampleRate == 48000)
            #expect(abs(audio.samples[0] - 0.25) < 0.0001)
            let decoded = try Image(contentsOf: root.appendingPathComponent("clip00000000.png"))
            #expect(decoded.getPixel(x: 0, y: 0).red > 0.99)
            #expect(decoded.getPixel(x: 1, y: 0).blue > 0.99)
            #expect(throws: MovieMakerError.self) { try MovieSequenceWriter(configuration: config) }
        }

        @Test(.enabled(if: GoldenFrame.isEnabled))
        func recordsRealWorldStepsAudioWarmupAndGracefulStop() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let previousBackend = unsafe RenderEngine.configurations.preferredBackend
            defer { unsafe RenderEngine.configurations.preferredBackend = previousBackend }
            unsafe RenderEngine.configurations.preferredBackend = GoldenFrame.activeBackend == .webgpu ? .webgpu : .metal
            let recorder = MovieMaker()
            let config = MovieRecordingConfiguration(
                outputURL: root.appendingPathComponent("world.png"), framesPerSecond: 30,
                width: 16, height: 8, frameCount: 10, warmupFrameCount: 2
            )
            var frames: [Int] = []
            var steps: [Float] = []
            let previousAudioServer = AudioServer.shared
            var sound: AudioPlaybackController?
            defer { sound?.stop() }
            let result = try await recorder.record(configuration: config, make: { app in
                app.addPlugin(TransformPlugin())
                    .addPlugin(RenderWorldPlugin())
                    .addPlugin(CameraPlugin())
                    .addPlugin(Core2DPlugin())
                    .addPlugin(AudioPlugin())
                app.spawn("Camera", bundle: Camera2D())
            }, update: { world, frame in
                frames.append(frame.index)
                if let delta = world.getResource(DeltaTime.self) { steps.append(delta.deltaTime) }
                if sound == nil {
                    var spec = SoundSpec()
                    spec.voices = [SoundVoice(wave: .sine, frequency: 440, duration: 1)]
                    let resource = try AudioResource.create(from: WAVWriter().encode(SoundSynth.render(spec)))
                    sound = AudioServer.shared.prepareAudio(resource).setLoop(true)
                    sound?.play()
                }
                // Wall-clock delays must not alter the movie's step or audio length.
                try await Task.sleep(for: .milliseconds(3))
            }, progress: { count in
                if count == 3 { recorder.stop() }
            })
            #expect(frames == [-2, -1, 0, 1, 2])
            #expect(steps.allSatisfy { abs($0 - 1.0 / 30) < 0.00001 })
            #expect(result.frameCount == 3 && result.status == .completed)
            #expect(!recorder.isRecording && recorder.recordedFrameCount == 3)
            #expect(AudioServer.shared === previousAudioServer)
            let audio = try WAVReader().decode(Data(contentsOf: root.appendingPathComponent("world.wav")))
            #expect(audio.frameCount == 4800)
            #expect(audio.samples.contains { abs($0) > 0.01 })
            let image = try Image(contentsOf: root.appendingPathComponent("world00000002.png"))
            #expect(image.width == 16 && image.height == 8)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("world00000003.png").path))
        }

        @Test func failedTakeKeepsAccurateManifest() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let recorder = MovieMaker()
            let config = MovieRecordingConfiguration(outputURL: root.appendingPathComponent("failed.png"), width: 1, height: 1, frameCount: 1)
            do {
                try await recorder.record(configuration: config, make: { _ in })
                Issue.record("Expected a missing render world error")
            } catch MovieMakerError.missingRenderWorld { }
            let result = try JSONDecoder().decode(MovieRecording.self, from: Data(contentsOf: root.appendingPathComponent("failed.movie.json")))
            #expect(result.frameCount == 0 && result.status == .failed)
            #expect(!recorder.isRecording)
        }

        @Test(.enabled(if: GoldenFrame.isEnabled))
        func cancellationFinalizesOnlyCompletedFrames() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let previousBackend = unsafe RenderEngine.configurations.preferredBackend
            defer { unsafe RenderEngine.configurations.preferredBackend = previousBackend }
            unsafe RenderEngine.configurations.preferredBackend = GoldenFrame.activeBackend == .webgpu ? .webgpu : .metal
            let maker = MovieMaker()
            let config = MovieRecordingConfiguration(outputURL: root.appendingPathComponent("cancel.png"), width: 8, height: 8, frameCount: 10)
            var task: Task<MovieRecording, any Error>?
            task = Task { @MainActor in
                try await maker.record(configuration: config, make: { app in
                    app.addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(CameraPlugin()).addPlugin(Core2DPlugin())
                    app.spawn("Camera", bundle: Camera2D())
                }, progress: { count in
                    if count == 1 { task?.cancel() }
                })
            }
            do {
                _ = try await task?.value
                Issue.record("Expected cancellation")
            } catch is CancellationError { }
            let result = try JSONDecoder().decode(MovieRecording.self, from: Data(contentsOf: root.appendingPathComponent("cancel.movie.json")))
            #expect(result.status == .cancelled && result.frameCount == 1)
            #expect(!maker.isRecording)
            let audio = try WAVReader().decode(Data(contentsOf: root.appendingPathComponent("cancel.wav")))
            #expect(audio.frameCount == 800)
        }

        @Test(.enabled(if: GoldenFrame.isEnabled))
        func lowFrameRatePreservesPhysicsTime() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let previousBackend = unsafe RenderEngine.configurations.preferredBackend
            defer { unsafe RenderEngine.configurations.preferredBackend = previousBackend }
            unsafe RenderEngine.configurations.preferredBackend = GoldenFrame.activeBackend == .webgpu ? .webgpu : .metal
            var world: World?
            let config = MovieRecordingConfiguration(outputURL: root.appendingPathComponent("physics.png"), framesPerSecond: 5, width: 8, height: 8, frameCount: 2)
            try await MovieMaker().record(configuration: config, make: { app in
                world = app.main
                app.addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(CameraPlugin()).addPlugin(Core2DPlugin())
                app.insertResource(MoviePhysicsTickCount())
                app.addSystem(MoviePhysicsTickSystem.self, on: .fixedUpdate)
                app.spawn("Camera", bundle: Camera2D())
            })
            #expect((world?.getResource(MoviePhysicsTickCount.self)?.value ?? 0) >= 23)
        }
    }
}

private struct MoviePhysicsTickCount: Resource { var value = 0 }

@PlainSystem
struct MoviePhysicsTickSystem {
    @ResMut<MoviePhysicsTickCount> private var ticks
    init(world _: World) {}
    func update(context _: UpdateContext) { ticks.value += 1 }
}
