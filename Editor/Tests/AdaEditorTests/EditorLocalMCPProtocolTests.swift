#if os(Windows)
import Foundation
import Testing

@testable import AdaEditor

struct EditorLocalMCPProtocolTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_STUDIO_MCP_TEST_PYTHON"] != nil))
    func negotiatesAnEarlierToolProtocolWithARealProcess() async throws {
        let python = try #require(ProcessInfo.processInfo.environment["ADA_STUDIO_MCP_TEST_PYTHON"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ada Local MCP \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/LocalMCP/server.py")
        let server = try EditorWindowsLocalMCP(executable: URL(fileURLWithPath: python), arguments: [fixture.path, "Fixture Space"], directory: directory)
        var failure: String?
        do {
            try await server.initialize()
            let tools = try await server.tools()
            #expect(tools.map { $0["name"].string } == ["echo", "second"])
            let reply = try await server.call("echo", arguments: ["value": "тест"])
            #expect(reply["structuredContent"]["server"].string == "Fixture Space")
            #expect(reply["structuredContent"]["value"].string == "тест")
        } catch {
            failure = "Earlier tool protocol was rejected: \(error)"
        }
        await server.disconnect()
        #expect(failure == nil)
    }
}
#endif
