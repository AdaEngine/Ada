import Foundation
import miniaudio

/// Owns the C engine for every sound that references it. Native device/mixer
/// synchronization belongs to miniaudio; browser pumping is single-threaded.
@unsafe
final class MiniAudioStorage {
    let enginePtr: UnsafeMutablePointer<ma_engine>
    #if WASM
    private let output: WebAudioOutput
    private var samples = [Float](repeating: 0, count: 4096 * 2)
    #endif

    init(headless: Bool = false) throws {
        let pointer = UnsafeMutablePointer<ma_engine>.allocate(capacity: 1)
        var config = ma_engine_config_init()
        config.channels = 2
        #if WASM
        config.noDevice = ma_bool32(MA_TRUE)
        config.sampleRate = 48_000
        #else
        if headless { config.noDevice = ma_bool32(MA_TRUE); config.sampleRate = 48_000 }
        #endif
        let result = ma_engine_init(&config, pointer)
        guard result == MA_SUCCESS else {
            pointer.deallocate()
            throw MAError.failed("Engine initialization failed", result)
        }
        #if WASM
        do { output = try WebAudioOutput() } catch {
            ma_engine_uninit(pointer); pointer.deallocate(); throw error
        }
        #endif
        enginePtr = pointer
    }
    deinit { ma_engine_uninit(enginePtr); enginePtr.deallocate() }
    func start() throws {
        #if WASM
        output.start()
        #else
        let result = ma_engine_start(enginePtr)
        if result != MA_SUCCESS { throw MAError.failed("Failed to start", result) }
        #endif
    }
    func stop() throws {
        #if WASM
        output.stop()
        #else
        let result = ma_engine_stop(enginePtr)
        if result != MA_SUCCESS { throw MAError.failed("Failed to stop", result) }
        #endif
    }
    func update() {
        #if WASM
        let frames = output.neededFrames
        guard frames > 0 else {
            return
        }
        samples.withUnsafeMutableBufferPointer { buffer in
            var read: ma_uint64 = 0
            let result = ma_engine_read_pcm_frames(enginePtr, buffer.baseAddress, ma_uint64(frames), &read)
            if result == MA_SUCCESS, read > 0 {
                output.submit(UnsafeBufferPointer(start: buffer.baseAddress, count: Int(read) * 2))
            }
        }
        #endif
    }
}
