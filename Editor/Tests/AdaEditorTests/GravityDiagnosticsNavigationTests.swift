import Foundation
import GravityLanguageCore
import GravityLanguageServerProtocol
import Testing

@Suite("AdaScript live diagnostics and navigation")
struct GravityDiagnosticsNavigationTests {
    @Test("Duplicate exported properties underline the second name before running")
    func duplicateExportedProperties() throws {
        let source = """
            @system(scheduler: "update", id: "game.main")
            class MainSystem {
                @export var speed: Int = 0
                @export var speed: Int = 0
                func update(context: AdaSystemContext) {}
            }
            """
        let diagnostics = GravityLanguageService().analyze(text: source).diagnostics
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostics.count == 1)
        #expect(diagnostic.message == "Duplicate property 'speed' in 'MainSystem'")
        #expect(diagnostic.severity == .error)
        #expect(
            diagnostic.range
                == GravitySourceRange(
                    start: GravitySourcePosition(line: 3, utf16Column: 16),
                    end: GravitySourcePosition(line: 3, utf16Column: 21)
                )
        )
    }

    @Test("Property diagnostics respect class and local scopes")
    func propertyScopes() {
        let source = """
            class First {
                var speed = 0
                static var speed = 0
                func update() { var speed = 1 }
                func reset() { var speed = 2 }
            }
            class Second { var speed = 3 }
            """
        #expect(GravityLanguageService().analyze(text: source).diagnostics.isEmpty)
    }

    @Test("Unfinished classes still report repeated var and const properties with UTF-16 ranges")
    func unfinishedDuplicate() throws {
        let source = "class Main { var speed = 0; /* 🎮 */ const speed = 1"
        let diagnostics = GravityLanguageService().analyze(text: source).diagnostics
        #expect(diagnostics.contains { $0.message == "Unclosed '{'" })
        let duplicate = try #require(diagnostics.first { $0.message.hasPrefix("Duplicate property") })
        let prefix = try #require(source.range(of: "speed", options: .backwards))
        #expect(duplicate.range.start.utf16Column == source[..<prefix.lowerBound].utf16.count)
        #expect(duplicate.range.end.utf16Column - duplicate.range.start.utf16Column == 5)
    }

    @Test("LSP publishes duplicate diagnostics on open and clears them on change")
    func diagnosticLifecycle() throws {
        let session = GravityLanguageServerSession()
        _ = session.handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["rootUri": NSNull()],
        ])
        let uri = "file:///tmp/Duplicate.ada"
        let opened = session.handle([
            "jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": [
                "textDocument": [
                    "uri": uri, "languageId": "adascript", "version": 1,
                    "text": "class Main { var speed = 0; var speed = 1 }",
                ]
            ],
        ])
        let openParams = try #require(opened.outgoingMessages.first?["params"] as? [String: Any])
        let diagnostics = try #require(openParams["diagnostics"] as? [[String: Any]])
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?["severity"] as? Int == 1)
        let changed = session.handle([
            "jsonrpc": "2.0", "method": "textDocument/didChange",
            "params": [
                "textDocument": ["uri": uri, "version": 2],
                "contentChanges": [["text": "class Main { var speed = 0 }"]],
            ],
        ])
        let changeParams = try #require(changed.outgoingMessages.first?["params"] as? [String: Any])
        #expect((changeParams["diagnostics"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("Navigable workspace components have a hover range at their use site", arguments: [false, true])
    func workspaceComponentHover(imported: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaScriptHover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let component = root.appendingPathComponent("VladComponent.ada")
        try "@component(id: \"test.vlad\") struct VladComponent { @export var someValue = 0; }".write(to: component, atomically: true, encoding: .utf8)
        let uri = root.appendingPathComponent("Main.ada").absoluteString
        let workspace = GravityWorkspace()
        workspace.configure(rootURIs: [root.absoluteString])
        let prefix = imported ? "import { VladComponent } from \"./VladComponent\";\n" : ""
        workspace.open(uri: uri, text: prefix + "/* 🎮 */ VladComponent().someValue = 0", version: 1)
        let line = imported ? 1 : 0
        let position = GravitySourcePosition(line: line, utf16Column: 14)
        #expect(workspace.definition(uri: uri, position: position)?.uri == component.absoluteString)
        let hover = try #require(workspace.hover(uri: uri, position: position))
        #expect(hover.contents.contains("VladComponent"))
        #expect(
            hover.range
                == GravitySourceRange(
                    start: GravitySourcePosition(line: line, utf16Column: 9),
                    end: GravitySourcePosition(line: line, utf16Column: 22)
                )
        )
        #expect(workspace.hover(uri: uri, position: GravitySourcePosition(line: line, utf16Column: 33)) == nil)
    }
}
