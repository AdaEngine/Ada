#if WASM
import JavaScriptKit

/// Browser WASI executes the mixer and JS bridge on its single event-loop thread.
/// JS copies each PCM block before returning; no pointer into WASM is retained.
final class WebAudioOutput {
    private let bridge: JSObject
    private let identifier: Double
    init() throws {
        guard let bridge = JSObject.global.__adaEngineAudio.object,
              let identifier = bridge.create?().number else {
            throw AudioError.engineInitializationFailed
        }
        self.bridge = bridge
        self.identifier = identifier
    }
    deinit { _ = bridge.destroy?(identifier) }
    func start() { _ = bridge.start?(identifier) }
    func stop() { _ = bridge.stop?(identifier) }
    var neededFrames: Int {
        let frames = bridge.neededFrames?(identifier).number ?? 0
        guard frames.isFinite, frames >= 0, frames <= 4096 else {
            return 0
        }
        return Int(frames)
    }
    func submit(_ samples: UnsafeBufferPointer<Float>) {
        let array = JSTypedArray<Float>(buffer: samples)
        _ = bridge.submit?(identifier, array.jsObject)
    }
}
#endif
