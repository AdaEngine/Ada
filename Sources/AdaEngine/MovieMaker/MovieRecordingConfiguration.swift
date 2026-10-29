import Foundation

/// Offline capture settings. Output is a lossless PNG sequence and optional stereo PCM WAV.
public struct MovieRecordingConfiguration: Sendable, Equatable {
    /// A `.png` path such as `Movies/trailer.png`. Frames are named `trailer00000000.png`.
    public var outputURL: URL
    public var framesPerSecond: Int
    public var width: Int
    public var height: Int
    public var frameCount: Int
    /// Simulation frames rendered before recording, useful for temporal effects and loading.
    public var warmupFrameCount: Int
    public var includesAudio: Bool
    /// Maximum real time to wait for a single GPU frame, independent of movie time.
    public var frameTimeout: Duration

    public init(
        outputURL: URL,
        framesPerSecond: Int = 60,
        width: Int = 1920,
        height: Int = 1080,
        frameCount: Int = 600,
        warmupFrameCount: Int = 0,
        includesAudio: Bool = true,
        frameTimeout: Duration = .seconds(30)
    ) {
        self.outputURL = outputURL
        self.framesPerSecond = framesPerSecond
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.warmupFrameCount = warmupFrameCount
        self.includesAudio = includesAudio
        self.frameTimeout = frameTimeout
    }

    public func validate() throws {
        guard outputURL.isFileURL, outputURL.pathExtension.lowercased() == "png" else {
            throw MovieMakerError.invalidConfiguration("Movie output must be a local .png path.")
        }
        guard (1...1000).contains(framesPerSecond), 48_000 % framesPerSecond == 0 else {
            throw MovieMakerError.invalidConfiguration("FPS must be in 1...1000 and divide the 48000 Hz audio mix rate.")
        }
        guard (1...8192).contains(width), (1...8192).contains(height), frameCount > 0, warmupFrameCount >= 0,
              frameTimeout > .zero else {
            throw MovieMakerError.invalidConfiguration("Use dimensions in 1...8192, a positive frame count and timeout, and nonnegative warmup.")
        }
        let maximumAudioFrames = UInt64(UInt32.max - 36) / UInt64((48_000 / framesPerSecond) * 4)
        guard !includesAudio || UInt64(frameCount) <= maximumAudioFrames else {
            throw MovieMakerError.invalidConfiguration("The recording exceeds the WAV 4 GiB limit; split it into shorter takes.")
        }
    }

    /// Parses Godot-style capture flags. Returns `nil` unless `--write-movie` is present.
    /// Relative paths resolve against `directory`, normally the game's project directory.
    public static func commandLine(
        _ arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        relativeTo directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) throws -> Self? {
        guard arguments.contains("--write-movie") else { return nil }
        var values: [String: String] = [:]
        var noAudio = false
        let flags: Set<String> = ["--write-movie", "--fixed-fps", "--resolution", "--quit-after", "--movie-warmup"]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--movie-no-audio" {
                noAudio = true
            } else if flags.contains(flag) {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"), values[flag] == nil else {
                    throw MovieMakerError.invalidConfiguration("Missing or duplicate value for \(flag).")
                }
                index += 1
                values[flag] = arguments[index]
            }
            index += 1
        }
        func integer(_ flag: String, fallback: Int) throws -> Int {
            guard let value = values[flag] else { return fallback }
            guard let number = Int(value) else { throw MovieMakerError.invalidConfiguration("Invalid integer for \(flag).") }
            return number
        }
        guard let path = values["--write-movie"] else { return nil }
        let resolution = (values["--resolution"] ?? "1920x1080").lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard resolution.count == 2, let width = Int(resolution[0]), let height = Int(resolution[1]) else {
            throw MovieMakerError.invalidConfiguration("Resolution must have the form 1920x1080.")
        }
        let config = try Self(
            outputURL: URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL,
            framesPerSecond: integer("--fixed-fps", fallback: 60),
            width: width,
            height: height,
            frameCount: integer("--quit-after", fallback: 600),
            warmupFrameCount: integer("--movie-warmup", fallback: 0),
            includesAudio: !noAudio
        )
        try config.validate()
        return config
    }
}

public enum MovieMakerError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case outputExists(URL)
    case missingRenderWorld
    case noActiveCamera
    case frameTimeout
    case unreadableFrame
    case recordingInProgress

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message): message
        case let .outputExists(url): "Movie output already exists: \(url.path)"
        case .missingRenderWorld: "Movie Maker requires RenderWorldPlugin and a camera render pipeline."
        case .noActiveCamera: "Movie Maker requires an active camera."
        case .frameTimeout: "Timed out waiting for the movie frame to finish rendering."
        case .unreadableFrame: "The renderer could not read the completed movie frame."
        case .recordingInProgress: "This Movie Maker is already recording."
        }
    }
}
