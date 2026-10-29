import AdaRender
import Foundation

/// Metadata saved next to the image sequence, including partial takes.
public struct MovieRecording: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case recording, completed, cancelled, failed }
    public let framesPerSecond: Int
    public let width: Int
    public let height: Int
    public var frameCount: Int
    public let imagePattern: String
    public let audioFile: String?
    public let audioSampleRate: Int?
    public var status: Status
    public var duration: Double { Double(frameCount) / Double(framesPerSecond) }
}

/// Serializes CPU encoding and file IO away from the application's main actor.
/// The caller awaits each append, bounding memory to one image and one audio block.
actor MovieSequenceWriter {
    private let configuration: MovieRecordingConfiguration
    private let stem: URL
    private let manifestURL: URL
    private var recording: MovieRecording
    private var audio: FileHandle?
    private var audioByteCount: UInt32 = 0

    init(configuration: MovieRecordingConfiguration) throws {
        self.configuration = configuration
        stem = configuration.outputURL.deletingPathExtension()
        manifestURL = stem.appendingPathExtension("movie.json")
        let directory = stem.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = stem.lastPathComponent
        let existing = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        // Reject a whole existing sequence, including incomplete takes missing frame zero.
        if let conflict = existing.first(where: { name in
            if name == prefix + ".wav" || name == prefix + ".movie.json" { return true }
            guard name.hasPrefix(prefix), name.lowercased().hasSuffix(".png") else { return false }
            let digits = name.dropFirst(prefix.count).dropLast(4)
            return digits.count >= 8 && digits.allSatisfy(\.isNumber)
        }) {
            throw MovieMakerError.outputExists(directory.appendingPathComponent(conflict))
        }
        recording = MovieRecording(
            framesPerSecond: configuration.framesPerSecond,
            width: configuration.width,
            height: configuration.height,
            frameCount: 0,
            imagePattern: prefix + "%08d.png",
            audioFile: configuration.includesAudio ? prefix + ".wav" : nil,
            audioSampleRate: configuration.includesAudio ? 48_000 : nil,
            status: .recording
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recording).write(to: manifestURL, options: .withoutOverwriting)
        if configuration.includesAudio {
            let url = stem.appendingPathExtension("wav")
            do {
                try Self.wavHeader(byteCount: 0).write(to: url, options: .withoutOverwriting)
                audio = try FileHandle(forUpdating: url)
            } catch {
                try? FileManager.default.removeItem(at: manifestURL)
                throw error
            }
        }
    }

    func append(image: Image, samples: [Float]) throws {
        guard image.width == configuration.width, image.height == configuration.height,
              samples.count == (48_000 / configuration.framesPerSecond) * 2,
              samples.allSatisfy(\.isFinite) else { throw MovieMakerError.unreadableFrame }
        let index = String(recording.frameCount)
        let paddedIndex = String(repeating: "0", count: max(0, 8 - index.count)) + index
        let frameURL = URL(fileURLWithPath: stem.path + paddedIndex + ".png")
        let imageData = try image.pngData()
        var pcm = Data(capacity: samples.count * 2)
        if audio != nil {
            for sample in samples {
                let value = UInt16(bitPattern: Int16((max(-1, min(1, sample)) * 32767).rounded()))
                pcm.append(UInt8(truncatingIfNeeded: value))
                pcm.append(UInt8(truncatingIfNeeded: value >> 8))
            }
        }
        try imageData.write(to: frameURL, options: .withoutOverwriting)
        do {
            if let audio {
                try audio.seekToEnd()
                try audio.write(contentsOf: pcm)
                // Keep the WAV readable after every completed frame, even before finish().
                try audio.seek(toOffset: 0)
                try audio.write(contentsOf: Self.wavHeader(byteCount: audioByteCount + UInt32(pcm.count)))
                audioByteCount += UInt32(pcm.count)
            }
        } catch {
            try? audio?.truncate(atOffset: UInt64(44) + UInt64(audioByteCount))
            try? FileManager.default.removeItem(at: frameURL)
            throw error
        }
        recording.frameCount += 1
    }

    func finish(status: MovieRecording.Status) throws -> MovieRecording {
        if let audio {
            try audio.seek(toOffset: 0)
            try audio.write(contentsOf: Self.wavHeader(byteCount: audioByteCount))
            try audio.synchronize()
            try audio.close()
            self.audio = nil
        }
        recording.status = status
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recording).write(to: manifestURL, options: .atomic)
        return recording
    }

    private static func wavHeader(byteCount: UInt32) -> Data {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            for index in 0..<MemoryLayout<T>.size { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        append(UInt32(36) + byteCount)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(2))
        append(UInt32(48_000))
        append(UInt32(48_000 * 4))
        append(UInt16(4))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(byteCount)
        return data
    }
}
