import AdaEngine
import Foundation
import Observation

@Observable
@MainActor
final class EditorAudioPreviewModel {
    enum PlaybackState {
        case stopped, loading, playing, paused
    }

    private(set) var state: PlaybackState = .stopped
    private(set) var errorKey: String?
    private(set) var errorDetail: String?
    var volume: Double = 1 {
        didSet { controller?.volume = Float(min(1, max(0, volume))) }
    }

    @ObservationIgnored private(set) var controller: AudioPlaybackController?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var completionTask: Task<Void, Never>?

    deinit {
        loadTask?.cancel()
        completionTask?.cancel()
        controller?.stop()
    }

    var statusKey: String {
        switch state {
        case .stopped: "Stopped"
        case .loading: "Loading audio…"
        case .playing: "Playing"
        case .paused: "Paused"
        }
    }

    func togglePlayback(path: String?) {
        if state == .playing {
            controller?.pause()
            completionTask?.cancel()
            state = .paused
            return
        }
        guard state != .loading else { return }
        errorKey = nil
        errorDetail = nil
        if let controller {
            beginPlayback(controller)
            return
        }
        guard let path else {
            errorKey = "Audio file is unavailable."
            return
        }
        state = .loading
        loadTask = Task { [weak self] in
            do {
                let data = try await Self.readAudio(at: path)
                try Task.checkCancellation()
                guard let self else { return }
                self.beginPlayback(try AudioServer.preparePreview(from: data))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorDetail = error.localizedDescription
                self?.state = .stopped
            }
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        completionTask?.cancel()
        completionTask = nil
        controller?.stop()
        controller = nil
        state = .stopped
    }

    private func beginPlayback(_ controller: AudioPlaybackController) {
        self.controller = controller
        controller.volume = Float(min(1, max(0, volume)))
        controller.play()
        state = .playing
        completionTask?.cancel()
        // Observe completion on the UI actor; miniaudio's completion callback runs on its mixer thread.
        completionTask = Task { [weak self, controller] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(50))
                    guard let self else { return }
                    if !controller.isPlaying {
                        self.controller = nil
                        self.state = .stopped
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    @concurrent
    private nonisolated static func readAudio(at path: String) async throws -> Data {
        try Task.checkCancellation()
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        try Task.checkCancellation()
        return data
    }
}
