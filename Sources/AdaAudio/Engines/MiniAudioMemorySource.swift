import Foundation
import miniaudio

/// Encoded bytes and the decoder both outlive the ma_sound data source. Each
/// copy owns an independent decoder/cursor while sharing immutable Data bytes.
@unsafe
final class MiniAudioMemorySource {
    let encodedData: Data
    let decoder: UnsafeMutablePointer<ma_decoder>
    private let bytes: UnsafeMutableRawPointer
    init(data: Data) throws {
        guard !data.isEmpty else { throw AudioError.soundInitializationFailed }
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: MemoryLayout<UInt64>.alignment)
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: bytes, count: data.count))
        let decoder = UnsafeMutablePointer<ma_decoder>.allocate(capacity: 1)
        let result = ma_decoder_init_memory(bytes, data.count, nil, decoder)
        guard result == MA_SUCCESS else {
            decoder.deallocate(); bytes.deallocate()
            throw MAError.failed("Sound decoding failed", result)
        }
        encodedData = data; self.bytes = bytes; self.decoder = decoder
    }
    deinit { ma_decoder_uninit(decoder); decoder.deallocate(); bytes.deallocate() }
}
