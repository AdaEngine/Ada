import Foundation
@testable import AdaEditor
import GravityLanguageCore
import GravityLanguageServerProtocol
import Testing

@Suite("AdaScript live diagnostics and navigation")
struct GravityDiagnosticsNavigationTests {
    @Test("Unknown call argument is diagnosed without compiling")
    func unknownSpawnArgument() throws {
        let source = """
            @system(scheduler: "update", id: "game.main")
            class MainSystem {
                func update(context: AdaSystemContext) {
                    // Add gameplay here.
                    context.world.spawn(components)
                }
            }
            """
        let diagnostic = try #require(GravityLanguageService().analyze(text: source).diagnostics.first)
        let line = "        context.world.spawn(components)"
        let start = try #require(line.range(of: "components"))
        #expect(diagnostic.message == "Unknown value 'components'")
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.range == GravitySourceRange(
            start: .init(line: 4, utf16Column: line[..<start.lowerBound].utf16.count),
            end: .init(line: 4, utf16Column: line[..<start.upperBound].utf16.count)
        ))
    }

    @Test("Declared arguments, labels, members and comments are not unknown values")
    func knownSpawnArguments() {
        let source = """
            class MainSystem {
                var saved = null
                func update(context: AdaSystemContext, components) {
                    // spawn(missing)
                    context.world.spawn(components)
                    context.world.spawn(self.saved)
                    context.world.spawn([Transform(position: Vector3.ZERO)])
                }
            }
            """
        #expect(GravityLanguageService().analyze(text: source).diagnostics.isEmpty)
    }

    @Test("Unknown named argument and member receiver are values too")
    func unknownNestedValues() {
        let source = "func update(context) { context.world.spawn(components: missing); context.world.spawn(unknown.value) }"
        let diagnostics = GravityLanguageService().analyze(text: source).diagnostics
        #expect(diagnostics.map(\.message) == ["Unknown value 'missing'", "Unknown value 'unknown'"])
    }

    @Test("Parameters and locals in another function do not resolve this call")
    func unrelatedLocalNames() {
        let source = """
            func other(components) { var saved = components }
            func update(context) { context.world.spawn(components); context.world.spawn(saved) }
            """
        let diagnostics = GravityLanguageService().analyze(text: source).diagnostics
        #expect(diagnostics.map(\.message) == ["Unknown value 'components'", "Unknown value 'saved'"])
    }

    @Test("LSP publishes and clears an unknown value without a build")
    func unknownValueLifecycle() throws {
        let session = GravityLanguageServerSession()
        _ = session.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["rootUri": NSNull()]])
        let uri = "file:///tmp/UnknownValue.ada"
        let opened = session.handle([
            "jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": ["textDocument": ["uri": uri, "languageId": "adascript", "version": 1, "text": "func update(context) { context.world.spawn(components) }"]],
        ])
        let openParams = try #require(opened.outgoingMessages.first?["params"] as? [String: Any])
        let diagnostics = try #require(openParams["diagnostics"] as? [[String: Any]])
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?["message"] as? String == "Unknown value 'components'")
        let changed = session.handle([
            "jsonrpc": "2.0", "method": "textDocument/didChange",
            "params": [
                "textDocument": ["uri": uri, "version": 2],
                "contentChanges": [["text": "func update(context, components) { context.world.spawn(components) }"]],
            ],
        ])
        let changeParams = try #require(changed.outgoingMessages.first?["params"] as? [String: Any])
        #expect((changeParams["diagnostics"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("Editor refreshes AdaScript diagnostics on edits without invoking a build")
    @MainActor
    func editorRefreshesDiagnosticsOnEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaScriptAnalysis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("Main.ada")
        let initial = "func update(context) { context.world.spawn([]) }"
        try initial.write(to: fileURL, atomically: true, encoding: .utf8)
        let document = EditorTextDocument(
            id: "main",
            title: "Main.ada",
            relativePath: "Main.ada",
            absolutePath: fileURL.path,
            language: .ada,
            content: initial
        )
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: root.path),
            workspaceService: SwiftPMWorkspaceService(),
            workbench: EditorWorkbenchViewModel(activeEditorTab: "Main.ada", openDocuments: [.text(document)], activeDocumentID: document.id)
        )
        viewModel.workbench.textDocumentBinding(documentID: document.id).wrappedValue = "func update(context) { context.world.spawn(components) }"
        for _ in 0..<40 {
            if viewModel.workbench.textDocument(id: document.id)?.diagnostics.contains(where: { $0.message == "Unknown value 'components'" }) == true {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(viewModel.workbench.textDocument(id: document.id)?.diagnostics.contains(where: { $0.message == "Unknown value 'components'" }) == true)

        viewModel.workbench.textDocumentBinding(documentID: document.id).wrappedValue = initial
        for _ in 0..<40 {
            if viewModel.workbench.textDocument(id: document.id)?.diagnostics.isEmpty == true {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(viewModel.workbench.textDocument(id: document.id)?.diagnostics.isEmpty == true)
    }

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
