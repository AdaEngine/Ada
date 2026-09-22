import Foundation
import GravityLanguageCore
import GravityLanguageServerProtocol
import Testing

@Suite("AdaScript language server")
struct GravityLanguageServerTests {
    @Test("Initialization options publish host component constructors")
    func hostConstructorInitialization() throws {
        let session = GravityLanguageServerSession()
        _ = session.handle([
            "id": 1,
            "jsonrpc": "2.0",
            "method": "initialize",
            "params": [
                "initializationOptions": [
                    "hostConstructors": [
                        ["name": "Health", "parameters": ["current", "maximum"]]
                    ]
                ],
                "rootUri": NSNull(),
            ],
        ])
        let uri = "file:///tmp/HostCatalog.ada"
        _ = session.handle([
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": [
                "textDocument": ["languageId": "adascript", "text": "Heal", "uri": uri, "version": 1]
            ],
        ])
        let completion = session.handle([
            "id": 2,
            "jsonrpc": "2.0",
            "method": "textDocument/completion",
            "params": [
                "position": ["character": 4, "line": 0],
                "textDocument": ["uri": uri],
            ],
        ])
        let message = try #require(completion.outgoingMessages.first)
        let result = try #require(message["result"] as? [String: Any])
        let items = try #require(result["items"] as? [[String: Any]])
        #expect(items.contains { $0["label"] as? String == "Health" })
    }

    @Test("Completion offers @view and AdaUI builders")
    func adaUIViewCompletion() {
        let service = GravityLanguageService()
        let annotationItems = service.completions(
            text: "@vi",
            position: GravitySourcePosition(line: 0, utf16Column: 3)
        )
        let viewItems = service.completions(
            text: "func body() { Te }",
            position: GravitySourcePosition(line: 0, utf16Column: 16)
        )
        let stateItems = service.completions(
            text: "@sta",
            position: GravitySourcePosition(line: 0, utf16Column: 4)
        )
        let previewItems = service.completions(
            text: "@pre",
            position: GravitySourcePosition(line: 0, utf16Column: 4)
        )

        #expect(annotationItems.contains { $0.label == "view" })
        #expect(previewItems.contains { $0.label == "previewable" })
        #expect(stateItems.contains { $0.label == "state" })
        #expect(viewItems.contains { $0.label == "Text" })
    }

    @Test("Completion understands document types and Ada query values")
    func semanticCompletion() throws {
        let service = GravityLanguageService()
        let source = """
            class MovementSystem {
                var speed = 1;
                func update(deltaTime, queries) {}
            }
            func main() {
                var system = MovementSystem();
                system.up
            }
            """
        let methodItems = service.completions(
            text: source,
            position: GravitySourcePosition(line: 6, utf16Column: 13)
        )
        let update = try #require(methodItems.first { $0.label == "update" })
        #expect(update.insertText == "update()")
        #expect(update.replacementRange.start == GravitySourcePosition(line: 6, utf16Column: 11))

        let querySource = """
            @query(Transform)
            var movers;
            func update(context) {
                for (var entity in movers) {
                    entity.i
                }
            }
            """
        let queryItems = service.completions(
            text: querySource,
            position: GravitySourcePosition(line: 4, utf16Column: 16)
        )
        #expect(queryItems.contains { $0.label == "id" })
    }

    @Test("Completion uses symbols from real workspace files")
    func workspaceCompletion() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaScriptLSP-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "class SharedSystem { func tick() {} }"
            .write(
                to: projectURL.appendingPathComponent("Shared.ada"),
                atomically: true,
                encoding: .utf8
            )

        let workspace = GravityWorkspace()
        workspace.configure(rootURIs: [projectURL.absoluteString])
        let currentURL = projectURL.appendingPathComponent("Current.ada")
        workspace.open(
            uri: currentURL.absoluteString,
            text: "import { SharedSystem } from \"./Shared\";\nSharedSystem.ti",
            version: 1
        )
        let items = workspace.completions(
            uri: currentURL.absoluteString,
            position: GravitySourcePosition(line: 1, utf16Column: 15)
        )

        #expect(workspace.analysis(for: currentURL.absoluteString)?.imports.first?.names == ["SharedSystem"])
        #expect(workspace.analysis(for: currentURL.absoluteString)?.diagnostics.isEmpty == true)
        #expect(items.contains { $0.label == "tick" && $0.insertText == "tick()" })
    }

    @Test("Workspace indexes generated AdaScript sources in hidden Ada directories")
    func generatedWorkspaceCompletion() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaScriptGenerated-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let generatedURL = projectURL.appendingPathComponent(".ada/generated", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedURL, withIntermediateDirectories: true)
        try "class GeneratedSystem { func update() {} }"
            .write(
                to: generatedURL.appendingPathComponent("Generated.gravity"),
                atomically: true,
                encoding: .utf8
            )

        let workspace = GravityWorkspace()
        workspace.configure(rootURIs: [projectURL.absoluteString])
        let currentURL = generatedURL.appendingPathComponent("Current.ada")
        workspace.open(
            uri: currentURL.absoluteString,
            text: "import { GeneratedSystem } from \"./Generated.gravity\";\nGeneratedSystem.up",
            version: 1
        )

        let items = workspace.completions(
            uri: currentURL.absoluteString,
            position: GravitySourcePosition(line: 1, utf16Column: 18)
        )
        #expect(items.contains { $0.label == "update" })
    }

    @Test("Definition resolves local and imported AdaScript methods")
    func definition() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaScriptDefinition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let sharedURL = projectURL.appendingPathComponent("Shared.ada")
        try "class SharedSystem { func tick() {} }".write(to: sharedURL, atomically: true, encoding: .utf8)

        let workspace = GravityWorkspace()
        workspace.configure(rootURIs: [projectURL.absoluteString])
        let currentURL = projectURL.appendingPathComponent("Current.ada")
        workspace.open(
            uri: currentURL.absoluteString,
            text: "import { SharedSystem } from \"./Shared\";\nSharedSystem.tick()",
            version: 1
        )

        let target = try #require(
            workspace.definition(
                uri: currentURL.absoluteString,
                position: GravitySourcePosition(line: 1, utf16Column: 15)
            )
        )
        #expect(target.uri == sharedURL.absoluteString)
        #expect(
            target.selectionRange
                == GravitySourceRange(
                    start: GravitySourcePosition(line: 0, utf16Column: 26),
                    end: GravitySourcePosition(line: 0, utf16Column: 30)
                )
        )
    }

    @Test("Workspace reports unresolved and escaping imports")
    func workspaceImportDiagnostics() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaScriptImports-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let workspace = GravityWorkspace()
        workspace.configure(rootURIs: [projectURL.absoluteString])
        let currentURL = projectURL.appendingPathComponent("Current.ada")
        workspace.open(
            uri: currentURL.absoluteString,
            text: """
                import { Missing } from "./Missing";
                import { Secret } from "../Secret";
                """,
            version: 1
        )

        let diagnostics = try #require(workspace.analysis(for: currentURL.absoluteString)?.diagnostics)
        #expect(diagnostics.contains { $0.message == "Unable to resolve import './Missing'" })
        #expect(diagnostics.contains { $0.message == "Import escapes the configured AdaScript workspace" })
    }

    @Test("Diagnostics report unfinished source without rejecting completion")
    func tolerantDiagnostics() {
        let service = GravityLanguageService()
        let source = "@system(scheduler: \"update\")\nclass Movement {\n    @que"
        let analysis = service.analyze(text: source)
        let completions = service.completions(
            text: source,
            position: GravitySourcePosition(line: 2, utf16Column: 8)
        )

        #expect(analysis.diagnostics.contains { $0.message == "Unclosed '{'" })
        #expect(completions.contains { $0.label == "query" })
    }

    @Test("Completion keeps type members while the class is unfinished")
    func unfinishedTypeCompletion() {
        let service = GravityLanguageService()
        let source = """
            class MovementSystem {
                func update() {}
                func run() {
                    this.up
            """
        let analysis = service.analyze(text: source)
        let completions = service.completions(
            text: source,
            position: GravitySourcePosition(line: 3, utf16Column: 15)
        )

        #expect(analysis.diagnostics.contains { $0.message == "Unclosed '{'" })
        #expect(completions.contains { $0.label == "update" })
    }

    @Test("LSP lifecycle publishes diagnostics and returns completion")
    func protocolLifecycle() throws {
        let session = GravityLanguageServerSession()
        try validateInitialization(of: session)

        let uri = "file:///tmp/Movement.ada"
        let opened = session.handle([
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": [
                "textDocument": [
                    "languageId": "gravity",
                    "text": "@que",
                    "uri": uri,
                    "version": 1,
                ]
            ],
        ])
        let diagnosticsNotification = try #require(opened.outgoingMessages.first)
        #expect(diagnosticsNotification["method"] as? String == "textDocument/publishDiagnostics")

        let completion = session.handle([
            "id": 2,
            "jsonrpc": "2.0",
            "method": "textDocument/completion",
            "params": [
                "position": ["character": 4, "line": 0],
                "textDocument": ["uri": uri],
            ],
        ])
        let response = try #require(completion.outgoingMessages.first)
        let result = try #require(response["result"] as? [String: Any])
        let items = try #require(result["items"] as? [[String: Any]])
        #expect(items.contains { $0["label"] as? String == "query" })

        _ = session.handle([
            "jsonrpc": "2.0",
            "method": "textDocument/didChange",
            "params": [
                "contentChanges": [["text": "func tick() {}\nfunc update() { tick(); }"]],
                "textDocument": ["uri": uri, "version": 2],
            ],
        ])
        let definition = session.handle([
            "id": 3,
            "jsonrpc": "2.0",
            "method": "textDocument/definition",
            "params": [
                "position": ["character": 18, "line": 1],
                "textDocument": ["uri": uri],
            ],
        ])
        try validateDefinition(definition, uri: uri)

        validateShutdown(of: session)
    }

    @Test("Framer accepts split and consecutive LSP messages")
    func messageFraming() throws {
        let first = try GravityLSPMessageFramer.frame(["id": 1, "jsonrpc": "2.0", "method": "shutdown"])
        let second = try GravityLSPMessageFramer.frame(["jsonrpc": "2.0", "method": "exit"])
        let combined = first + second
        let splitIndex = combined.count / 3
        var framer = GravityLSPMessageFramer()

        #expect(try framer.append(combined.prefix(splitIndex)).isEmpty)
        let payloads = try framer.append(combined.dropFirst(splitIndex))
        #expect(payloads.count == 2)
        let firstMessage = try #require(JSONSerialization.jsonObject(with: payloads[0]) as? [String: Any])
        #expect(firstMessage["method"] as? String == "shutdown")
    }

    @Test("Framer rejects negative content lengths")
    func negativeContentLength() {
        var framer = GravityLSPMessageFramer()
        #expect(throws: GravityLSPFramingError.invalidContentLength) {
            try framer.append(Data("Content-Length: -1\r\n\r\n".utf8))
        }
    }

    private func validateInitialization(of session: GravityLanguageServerSession) throws {
        let initialize = session.handle([
            "id": 1,
            "jsonrpc": "2.0",
            "method": "initialize",
            "params": ["rootUri": NSNull()],
        ])
        let response = try #require(initialize.outgoingMessages.first)
        let result = try #require(response["result"] as? [String: Any])
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["positionEncoding"] as? String == "utf-16")
        #expect(capabilities["definitionProvider"] as? Bool == true)
        #expect(capabilities["hoverProvider"] as? Bool == true)
        #expect(capabilities["semanticTokensProvider"] != nil)
        #expect(capabilities["signatureHelpProvider"] != nil)
    }

    private func validateShutdown(of session: GravityLanguageServerSession) {
        let shutdown = session.handle(["id": 4, "jsonrpc": "2.0", "method": "shutdown"])
        #expect(shutdown.outgoingMessages.count == 1)
        #expect(session.handle(["jsonrpc": "2.0", "method": "exit"]).exitCode == 0)
    }

    private func validateDefinition(_ result: GravityLanguageServerAction, uri: String) throws {
        let response = try #require(result.outgoingMessages.first)
        let location = try #require(response["result"] as? [String: Any])
        #expect(location["targetUri"] as? String == uri)
    }
}
