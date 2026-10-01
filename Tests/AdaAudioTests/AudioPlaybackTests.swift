@testable import AdaAudio
import Foundation
import miniaudio
import Testing

@Suite("Audio PCM playback")
struct AudioPlaybackTests {
    @Test("Encoded WAV remains valid after its temporary bytes are released; copies have independent playback cursors")
    func decodesOwnedMemoryAndCopies() throws {
        let engine = unsafe try MiniAudioStorage(headless: true)
        func sound() throws -> any Sound { unsafe try MiniSound(from: Self.wav(), engine: engine) }
        let prototype = try sound()
        let first = try prototype.copy()
        first.start()
        let pcm = unsafe try render(engine, frames: 2400)
        #expect(pcm.contains { abs($0) > 0.05 })
        first.stop()
        let second = try prototype.copy()
        second.start()
        let copyPCM = unsafe try render(engine, frames: 2400)
        #expect(zip(pcm, copyPCM).allSatisfy { abs($0 - $1) < 0.001 })
        second.pause()
        #expect(second.state == .paused)
        second.stop()
        #expect(second.state == .stopped)
    }
    @Test("Invalid encoded data fails without leaving an initialized sound")
    func invalidData() throws {
        let engine = unsafe try MiniAudioStorage(headless: true)
        #expect(throws: (any Error).self) { unsafe try MiniSound(from: Data([1, 2, 3]), engine: engine) }
        #expect(throws: (any Error).self) { unsafe try MiniSound(from: Data(), engine: engine) }
    }
    @Test("Sound owns the native engine until it finishes using it")
    func ownsEngine() throws {
        let sound: any Sound = try {
            let engine = unsafe try MiniAudioStorage(headless: true)
            return unsafe try MiniSound(from: Self.wav(), engine: engine)
        }()
        sound.start(); sound.stop()
        #expect(sound.state == .stopped)
    }
    private func render(_ engine: MiniAudioStorage, frames: Int) throws -> [Float] {
        var pcm = [Float](repeating: 0, count: frames * 2)
        var read: ma_uint64 = 0
        let result = unsafe pcm.withUnsafeMutableBufferPointer { ma_engine_read_pcm_frames(engine.enginePtr, $0.baseAddress, ma_uint64(frames), &read) }
        #expect(result == MA_SUCCESS)
        #expect(read == ma_uint64(frames))
        return pcm
    }
    static func wav() -> Data {
        let count = 4800
        var data = Data()
        func u16(_ value: UInt16) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
        func u32(_ value: UInt32) { u16(UInt16(truncatingIfNeeded: value)); u16(UInt16(truncatingIfNeeded: value >> 16)) }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + count * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(count * 2))
        for frame in 0..<count { u16(UInt16(bitPattern: Int16(sin(Double(frame) * 2 * .pi * 440 / 48000) * 12000))) }
        return data
    }
}
