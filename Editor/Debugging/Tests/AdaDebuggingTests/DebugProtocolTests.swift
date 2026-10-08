import Foundation
import Testing
@testable import AdaDebugging

@Suite("Debugger framing")
struct DebugProtocolTests {
    @Test func fragmentedUnicodeAndMultipleMessages() throws {
        let message = DebugJSON.object(["event": .string("output"), "text": .string("Привет 🎮")])
        let encoded = try DebugMessageFramer.encode(message)
        var framer = DebugMessageFramer()
        var received: [DebugJSON] = []
        for byte in encoded + encoded { received += try framer.append(Data([byte])) }
        #expect(received == [message, message])
        try framer.finish()
    }

    @Test(arguments: ["-1", "0", "16777217", "oops", "1\r\nContent-Length: 1"])
    func rejectsInvalidLengths(_ value: String) {
        var framer = DebugMessageFramer()
        #expect(throws: (any Error).self) {
            _ = try framer.append(Data("Content-Length: \(value)\r\n\r\n".utf8))
        }
    }

    @Test func rejectsTruncatedMessage() throws {
        var framer = DebugMessageFramer()
        _ = try framer.append(Data("Content-Length: 10\r\n\r\n{".utf8))
        #expect(throws: (any Error).self) { try framer.finish() }
    }
}
