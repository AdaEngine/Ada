import miniaudio

/// Pulls the game mixer without an audio device. Only the recording task and its
/// child tasks see this server, so an editor's live audio keeps its own server.
@MainActor
package final class OfflineAudioRenderer {
    package static let sampleRate = 48_000
    package let server: AudioServer
    private let engine: MiniAudioEngine

    package init() throws {
        engine = try MiniAudioEngine(headless: true)
        server = AudioServer(engine: engine)
    }

    package func render(frameCount: Int) throws -> [Float] {
        var samples = [Float](repeating: 0, count: frameCount * 2)
        var read: ma_uint64 = 0
        let start = unsafe ma_engine_get_time_in_pcm_frames(engine.engine.enginePtr)
        let result = unsafe samples.withUnsafeMutableBufferPointer { buffer in
            unsafe ma_engine_read_pcm_frames(engine.engine.enginePtr, buffer.baseAddress, ma_uint64(frameCount), &read)
        }
        guard result == MA_SUCCESS else {
            throw MAError.failed("Offline audio rendering failed", result)
        }
        // miniaudio zero-fills short reads when the graph has no playing nodes.
        // Its graph clock must still advance through those silent movie frames.
        let timeResult = unsafe ma_engine_set_time_in_pcm_frames(engine.engine.enginePtr, start + ma_uint64(frameCount))
        guard timeResult == MA_SUCCESS else { throw MAError.failed("Offline audio clock failed", timeResult) }
        return samples
    }
}
