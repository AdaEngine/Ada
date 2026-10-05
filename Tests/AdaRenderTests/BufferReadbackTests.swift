@testable import AdaRender
import Foundation
import Testing

@Suite
struct BufferReadbackTests {
    @Test
    func headlessReadbackReturnsWrittenBytesAndAnOwnedCopy() async throws {
        let device = HeadlessRenderBackend().renderDevice
        let buffer = device.createBuffer(label: "Readback", length: 16, options: .storageShared)
        var pattern: [UInt8] = Array(0..<16)
        buffer.setElements(&pattern)
        let original = try await buffer.readData()
        #expect(original == Data(pattern))
        pattern = Array(repeating: 42, count: 16)
        buffer.setElements(&pattern)
        let changed = try await buffer.readData()
        #expect(changed == Data(pattern))
        #expect(original == Data(Array(0..<16)))
    }
}
