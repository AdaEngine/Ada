@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Editor Movie Maker GPU", .serialized)
struct EditorMovieMakerGPUTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAEDITOR_MOVIE_GPU"] == "1"))
    func projectToolbarRecordsRealSceneAndRejectsOverwrite() async throws {
        #if os(Windows) || os(Linux)
        unsafe RenderEngine.configurations.preferredBackend = .webgpu
        #else
        unsafe RenderEngine.configurations.preferredBackend = .metal
        #endif
        let root = try movieEditorFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try """
        @system(id: "movie.fixture", scheduler: "update")
        class MovieFixture { func update(context) {} }
        """.write(to: root.appendingPathComponent("Sources/Main.ada"), atomically: true, encoding: .utf8)
        EditorComponentRegistry.registerBuiltIns()
        var scene = EditorSceneModel.default(projectName: "Movie")
        _ = scene.addEntity(preset: .camera)
        _ = scene.addEntity(preset: .sprite)
        try JSONEncoder().encode(scene).write(to: root.appendingPathComponent("Assets/Main.ascn"))
        let project = AdaProject(
            schemaVersion: 3,
            paths: AdaProjectPaths(sources: "Sources", assets: "Assets"),
            build: AdaProjectBuild(system: .adaScript),
            runtime: AdaProjectRuntime(moduleName: "Movie", entry: .init(scene: "Assets/Main.ascn"))
        )
        try ProjectSystem.saveProject(project, at: root)
        let viewModel = EditorViewModel(project: EditorProjectReference(name: "Movie", path: root.path))
        let movie = viewModel.movieMaker
        movie.settings.framesPerSecond = "30"
        movie.settings.width = "37"
        movie.settings.height = "19"
        movie.settings.duration = "0.1"
        movie.settings.outputPath = "Movies/clip.png"
        viewModel.startMovieRecording()
        #expect(movie.isBusy && viewModel.isProjectRunning)
        try await wait(movie)
        #expect(movie.phase == .completed, Comment(rawValue: movie.errorMessage ?? movie.statusText))
        #expect(movie.savedFrames == 3)
        #expect(!viewModel.isProjectRunning)
        let image = try Image(contentsOf: root.appendingPathComponent("Movies/clip00000002.png"))
        #expect(image.width == 37 && image.height == 19)
        let audio = try WAVReader().decode(Data(contentsOf: root.appendingPathComponent("Movies/clip.wav")))
        #expect(audio.frameCount == 4800 && audio.channels == 2)
        #expect(try EditorMovieMakerSettings.load(in: root) == movie.settings)
        let original = try Data(contentsOf: root.appendingPathComponent("Movies/clip00000000.png"))
        viewModel.startMovieRecording()
        try await wait(movie)
        #expect(movie.phase == .failed)
        #expect(try Data(contentsOf: root.appendingPathComponent("Movies/clip00000000.png")) == original)
    }

    private func wait(_ model: EditorMovieMakerModel) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while model.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isBusy)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAEDITOR_MOVIE_GPU"] == "1"))
    func currentSceneStopsGracefullyAndPreparationCanBeCancelled() async throws {
        #if os(Windows) || os(Linux)
        unsafe RenderEngine.configurations.preferredBackend = .webgpu
        #else
        unsafe RenderEngine.configurations.preferredBackend = .metal
        #endif
        let root = try movieEditorFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        EditorComponentRegistry.registerBuiltIns()
        var scene = EditorSceneModel.default(projectName: "Scene Movie")
        _ = scene.addEntity(preset: .camera)
        let sceneURL = root.appendingPathComponent("Scene.ascn")
        try JSONEncoder().encode(scene).write(to: sceneURL)
        let movie = EditorMovieMakerModel(projectURL: root)
        movie.settings.target = .currentScene
        movie.settings.framesPerSecond = "30"
        movie.settings.width = "32"
        movie.settings.height = "16"
        movie.settings.duration = "60"
        let source = EditorMovieMakerSource.scene(url: sceneURL, assets: root, runtime: nil)
        movie.start(source: source)
        let deadline = ContinuousClock.now + .seconds(30)
        while movie.isBusy && movie.savedFrames < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        movie.stop()
        try await wait(movie)
        #expect(movie.phase == .completed, Comment(rawValue: movie.errorMessage ?? movie.statusText))
        #expect(movie.savedFrames >= 2 && movie.savedFrames < 1800)
        let manifest = try JSONDecoder().decode(MovieRecording.self, from: Data(contentsOf: root.appendingPathComponent("Movies/clip.movie.json")))
        #expect(manifest.frameCount == movie.savedFrames && manifest.status == .completed)
        movie.settings.outputPath = "Movies/cancel.png"
        movie.start(source: source)
        movie.cancel()
        try await wait(movie)
        #expect(movie.phase == .cancelled)
        #expect(!movie.isBusy)
    }
}
