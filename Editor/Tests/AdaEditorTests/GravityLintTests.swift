import Foundation
import GravityLanguageCore
import GravityLanguageServerProtocol
import Testing

@Suite("AdaScript live style diagnostics")
struct GravityLintTests {
    @Test("Workspace reads the current buffer and clears style warnings on change")
    func workspaceChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaLint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Main.ada")
        try "var speed = 1;".write(to: file, atomically: true, encoding: .utf8)
        let workspace = GravityWorkspace()
        workspace.configure(rootURIs: [root.absoluteString])
        workspace.open(uri: file.absoluteString, text: "var speed=1;", version: 1)
        let diagnostics = try #require(workspace.analysis(for: file.absoluteString)?.diagnostics)
        #expect(diagnostics.map(\.code) == ["operator_spacing"])
        #expect(diagnostics.allSatisfy { $0.severity == .warning })
        workspace.change(uri: file.absoluteString, text: "var speed = 1;", version: 2)
        #expect(workspace.analysis(for: file.absoluteString)?.diagnostics.isEmpty == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == "var speed = 1;")
    }

    @Test("LSP publishes style rule identifiers, warning severity and source ranges")
    func protocolDiagnostics() throws {
        let session = GravityLanguageServerSession()
        _ = session.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["rootUri": NSNull()]])
        let uri = FileManager.default.temporaryDirectory.appendingPathComponent("Lint-\(UUID().uuidString).ada").absoluteString
        let opened = session.handle([
            "jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": ["textDocument": ["uri": uri, "languageId": "adascript", "version": 1, "text": "var speed=1;"]],
        ])
        let params = try #require(opened.outgoingMessages.first?["params"] as? [String: Any])
        let diagnostics = try #require(params["diagnostics"] as? [[String: Any]])
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostics.count == 1)
        #expect(diagnostic["severity"] as? Int == 2)
        #expect(diagnostic["code"] as? String == "operator_spacing")
        #expect(diagnostic["source"] as? String == "adascript-lint")
        let range = try #require(diagnostic["range"] as? [String: Any])
        let start = try #require(range["start"] as? [String: Int])
        #expect(start == ["line": 0, "character": 9])
        let changed = session.handle([
            "jsonrpc": "2.0", "method": "textDocument/didChange",
            "params": ["textDocument": ["uri": uri, "version": 2], "contentChanges": [["text": "var speed = 1;"]]],
        ])
        let changedParams = try #require(changed.outgoingMessages.first?["params"] as? [String: Any])
        #expect((changedParams["diagnostics"] as? [[String: Any]])?.isEmpty == true)
    }
}
