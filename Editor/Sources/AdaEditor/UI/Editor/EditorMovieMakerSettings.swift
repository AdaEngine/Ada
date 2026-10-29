import AdaEngine
import Foundation

enum EditorMovieMakerTarget: String, Codable, CaseIterable, Sendable {
    case project, currentScene
    var title: String { self == .project ? "Project" : "Current Scene" }
}

/// Project-local capture preferences retain editable text, including custom resolutions.
struct EditorMovieMakerSettings: Codable, Equatable, Sendable {
    var target: EditorMovieMakerTarget = .project
    var framesPerSecond = "60"
    var width = "1920"
    var height = "1080"
    var duration = "10"
    var outputPath = "Movies/clip.png"
    var includesAudio = true

    static func settingsURL(in project: URL) -> URL {
        project.appendingPathComponent(".ada/workspace/movie-maker.json")
    }

    static func load(in project: URL) throws -> Self {
        let url = settingsURL(in: project)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save(in project: URL) throws {
        let url = Self.settingsURL(in: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    func configuration(in project: URL) throws -> MovieRecordingConfiguration {
        guard let fps = Int(framesPerSecond), (1...1000).contains(fps), 48_000 % fps == 0 else {
            throw EditorMovieMakerError.invalidFPS
        }
        guard let width = Int(width), let height = Int(height), (1...8192).contains(width), (1...8192).contains(height) else {
            throw EditorMovieMakerError.invalidResolution
        }
        guard let seconds = Double(duration.replacingOccurrences(of: ",", with: ".")), seconds.isFinite, seconds > 0,
              (seconds * Double(fps)).isFinite, seconds * Double(fps) < Double(Int.max) else {
            throw EditorMovieMakerError.invalidDuration
        }
        let path = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, URL(fileURLWithPath: path).pathExtension.lowercased() == "png" else {
            throw EditorMovieMakerError.invalidPath
        }
        let configuration = MovieRecordingConfiguration(
            outputURL: URL(fileURLWithPath: path, relativeTo: project).standardizedFileURL,
            framesPerSecond: fps,
            width: width,
            height: height,
            frameCount: max(1, Int((seconds * Double(fps)).rounded(.up))),
            includesAudio: includesAudio
        )
        do { try configuration.validate() } catch { throw EditorMovieMakerError.audioLimit }
        return configuration
    }
}

enum EditorMovieMakerError: LocalizedError {
    case invalidFPS, invalidResolution, invalidDuration, invalidPath, audioLimit
    case noProject, noScene, unsupportedProject, saveFailed, runtime(String)

    var errorDescription: String? {
        key
    }

    var key: String {
        switch self {
        case .invalidFPS: "Choose an FPS that divides 48000, such as 24, 30 or 60."
        case .invalidResolution: "Width and height must be between 1 and 8192 pixels."
        case .invalidDuration: "Enter a recording duration greater than zero."
        case .invalidPath: "Enter a PNG output path, such as Movies/clip.png."
        case .audioLimit: "This take exceeds the WAV size limit. Choose a shorter duration."
        case .noProject: "Open a project before recording a movie."
        case .noScene: "Open a scene with a game camera before recording."
        case .unsupportedProject: "For Swift projects, choose Current Scene to record Scene Play."
        case .saveFailed: "Save the project documents before recording."
        case .runtime: "The game could not start."
        }
    }

    @MainActor var message: String {
        if case let .runtime(detail) = self { return L10n.text("The game could not start: \(detail)") }
        return L10n.tr(key)
    }
}
