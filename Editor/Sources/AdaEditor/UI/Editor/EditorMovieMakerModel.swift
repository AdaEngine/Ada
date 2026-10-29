import AdaEngine
import Foundation
import Observation

@Observable
@MainActor
final class EditorMovieMakerModel {
    enum Phase { case idle, preparing, recording, stopping, completed, cancelled, failed }
    var settings = EditorMovieMakerSettings()
    var isPresented = false
    private(set) var phase: Phase = .idle
    private(set) var savedFrames = 0
    private(set) var totalFrames = 0
    private(set) var errorMessage: String?
    private(set) var outputURL: URL?
    @ObservationIgnored private let recorder = MovieMaker()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let projectURL: URL?

    init(projectURL: URL? = nil) {
        self.projectURL = projectURL
        if let projectURL {
            do { settings = try EditorMovieMakerSettings.load(in: projectURL) }
            catch { errorMessage = L10n.text("Movie Maker settings could not be loaded: \(error.localizedDescription)") }
        }
    }

    deinit { task?.cancel() }

    var isBusy: Bool { phase == .preparing || phase == .recording || phase == .stopping }
    var progress: Float { totalFrames > 0 ? Float(savedFrames) / Float(totalFrames) : 0 }
    var validationMessage: String? {
        guard let projectURL else { return EditorMovieMakerError.noProject.message }
        do { _ = try settings.configuration(in: projectURL); return nil }
        catch let error as EditorMovieMakerError { return error.message }
        catch { return error.localizedDescription }
    }
    var statusText: String {
        switch phase {
        case .idle: L10n.text("Ready to record")
        case .preparing: L10n.text("Preparing the game…")
        case .recording: L10n.text("Recorded \(savedFrames) of \(totalFrames) frames")
        case .stopping: L10n.text("Finishing the current frame…")
        case .completed: L10n.text("Movie saved · \(savedFrames) frames")
        case .cancelled: L10n.text("Recording cancelled. Completed frames were saved.")
        case .failed: L10n.text("Movie recording failed")
        }
    }

    func report(_ error: any Error) {
        phase = .failed
        switch error {
        case let error as EditorMovieMakerError: errorMessage = error.message
        case MovieMakerError.outputExists:
            errorMessage = L10n.text("A take already exists at this path. Choose another file name.")
        case MovieMakerError.noActiveCamera:
            errorMessage = EditorMovieMakerError.noScene.message
        case MovieMakerError.frameTimeout:
            errorMessage = L10n.text("The game frame took too long to render. Try recording again.")
        case MovieMakerError.unreadableFrame:
            errorMessage = L10n.text("The renderer could not read the movie frame.")
        case MovieMakerError.missingRenderWorld:
            errorMessage = L10n.text("The game needs a camera and a render pipeline to record a movie.")
        default: errorMessage = error.localizedDescription
        }
    }

    func saveSettings() {
        guard let projectURL else { return }
        do { try settings.save(in: projectURL) }
        catch { errorMessage = L10n.text("Movie Maker settings could not be saved: \(error.localizedDescription)") }
    }

    func start(source: EditorMovieMakerSource) {
        guard !isBusy, let projectURL else { return }
        let configuration: MovieRecordingConfiguration
        do {
            configuration = try settings.configuration(in: projectURL)
            try settings.save(in: projectURL)
        } catch { report(error); return }
        phase = .preparing
        errorMessage = nil
        savedFrames = 0
        totalFrames = configuration.frameCount
        outputURL = configuration.outputURL
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            do {
                let runtime = try await source.prepare()
                defer { runtime.finish() }
                try Task.checkCancellation()
                let result = try await recorder.record(configuration: configuration, make: { app in
                    try runtime.configure(app)
                }, update: { world, _ in
                    try await runtime.prepareScene(in: world)
                    if self.phase != .stopping { self.phase = .recording }
                }, progress: { count in self.savedFrames = count })
                savedFrames = result.frameCount
                phase = .completed
            } catch is CancellationError {
                phase = .cancelled
            } catch { report(error) }
        }
    }

    /// A normal stop finalizes the current frame; closing the workspace cancels preparation too.
    func stop() {
        guard isBusy else { return }
        if phase == .preparing { task?.cancel() }
        recorder.stop()
        phase = .stopping
    }

    func cancel() { task?.cancel() }
}
