import Foundation
import GravityLanguageCore
import GravityLanguageServerProtocol
import Testing

@Suite("AdaScript semantic language features")
struct GravityLanguageSemanticTests {
    @Test("Async declarations remain navigable in AdaScript")
    func asyncFunctionsAreRecognized() {
        let service = GravityLanguageService()
        let source = "async func requestConfirmation() { var answer = await wait_confirmation(); }"
        let analysis = service.analyze(text: source)
        #expect(analysis.symbols.contains { $0.name == "requestConfirmation" && $0.detail == "AdaScript async function" })
        let completions = service.completions(text: "as", position: GravitySourcePosition(line: 0, utf16Column: 2))
        #expect(completions.contains { $0.label == "async func" })
    }

    @Test("Annotated lifecycle parameters expose typed host APIs")
    func annotatedLifecycleCompletion() {
        let service = GravityLanguageService(hostConstructors: [
            GravityHostConstructor(name: "Health", parameters: ["current", "maximum"]),
            GravityHostConstructor(name: "Transform", parameters: ["rotation", "scale", "position"]),
        ])
        let systemSource = """
            @system(id: "movement")
            class MovementSystem {
                func update(context) {
                    context.
                }
            }
            """
        let systemItems = service.completions(
            text: systemSource,
            position: GravitySourcePosition(line: 3, utf16Column: 16)
        )
        #expect(systemItems.contains { $0.label == "deltaTime" })
        #expect(systemItems.contains { $0.label == "world" })

        let commandSource = """
            @system(id: "commands")
            class CommandsSystem {
                func update(context) {
                    context.world.commands.sp
                }
            }
            """
        let commandItems = service.completions(
            text: commandSource,
            position: GravitySourcePosition(line: 3, utf16Column: 33)
        )
        #expect(commandItems.contains { $0.label == "spawn" })

        let worldSource = """
            @system(id: "world")
            class WorldSystem {
                func update(context) {
                    context.world.sp
                }
            }
            """
        let worldItems = service.completions(
            text: worldSource,
            position: GravitySourcePosition(line: 3, utf16Column: 24)
        )
        #expect(worldItems.contains { $0.label == "spawn" })

        let constructorItems = service.completions(
            text: "Tran",
            position: GravitySourcePosition(line: 0, utf16Column: 4)
        )
        #expect(constructorItems.contains { $0.label == "Transform" })
        let healthItems = service.completions(
            text: "Heal",
            position: GravitySourcePosition(line: 0, utf16Column: 4)
        )
        #expect(healthItems.contains { $0.label == "Health" })

        let constructorHover = service.hover(
            text: "Transform(position: Vector3.ZERO)",
            position: GravitySourcePosition(line: 0, utf16Column: 2)
        )
        #expect(constructorHover?.contents == "Transform(rotation:, scale:, position:) -> Component")

        let vectorItems = service.completions(
            text: "Vector3.Z",
            position: GravitySourcePosition(line: 0, utf16Column: 9)
        )
        #expect(vectorItems.contains { $0.label == "ZERO" })

        let toolSource = """
            @tool(id: "com.example.tool", permissions: [])
            class ExampleTool {
                func activate(editor) {
                    editor.add
                }
            }
            """
        let toolItems = service.completions(
            text: toolSource,
            position: GravitySourcePosition(line: 3, utf16Column: 18)
        )
        #expect(toolItems.contains { $0.label == "addCommand" })
        #expect(toolItems.contains { $0.label == "addPanel" })
        #expect(toolItems.contains { $0.label == "addFormatter" })

        let annotationItems = service.completions(
            text: "@to",
            position: GravitySourcePosition(line: 0, utf16Column: 3)
        )
        #expect(annotationItems.contains { $0.label == "tool" })
    }

    @Test("Semantic tokens identify annotations and methods")
    func semanticTokens() {
        let service = GravityLanguageService()
        let source = Self.systemSource
        let tokens = service.semanticTokens(text: source)

        #expect(
            tokens.contains {
                $0.kind == .macro
                    && $0.range.start == GravitySourcePosition(line: 0, utf16Column: 0)
                    && $0.range.end == GravitySourcePosition(line: 0, utf16Column: 1)
            }
        )
        #expect(
            tokens.contains {
                $0.kind == .macro && $0.range.start == GravitySourcePosition(line: 0, utf16Column: 1)
            }
        )
        #expect(
            tokens.contains {
                $0.kind == .method && $0.range.start == GravitySourcePosition(line: 2, utf16Column: 9)
            }
        )
        #expect(
            tokens.contains {
                $0.kind == .method && $0.range.start == GravitySourcePosition(line: 3, utf16Column: 31)
            }
        )
        let hover = service.hover(text: source, position: GravitySourcePosition(line: 3, utf16Column: 32))
        #expect(hover?.contents.contains("spawn(components)") == true)
        let signature = service.signatureHelp(text: source, position: GravitySourcePosition(line: 3, utf16Column: 37))
        #expect(signature?.activeParameter == 0)

        let multilineComments = service.semanticTokens(text: "/* first\nsecond */")
        #expect(multilineComments.filter { $0.kind == .comment }.count == 2)
        #expect(multilineComments.allSatisfy { $0.range.start.line == $0.range.end.line })
    }

    @Test("LSP publishes semantic tokens and host API hover")
    func semanticProtocol() throws {
        let session = GravityLanguageServerSession()
        try validateInitialization(of: session)
        let uri = "file:///tmp/Semantic.ada"
        _ = session.handle([
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": [
                "textDocument": ["languageId": "adascript", "text": Self.systemSource, "uri": uri, "version": 1]
            ],
        ])
        let response = session.handle([
            "id": 2,
            "jsonrpc": "2.0",
            "method": "textDocument/semanticTokens/full",
            "params": ["textDocument": ["uri": uri]],
        ])
        let message = try #require(response.outgoingMessages.first)
        let result = try #require(message["result"] as? [String: Any])
        let data = try #require(result["data"] as? [Int])
        #expect(!data.isEmpty)
        #expect(data.count.isMultiple(of: 5))

        let hoverResponse = session.handle([
            "id": 3,
            "jsonrpc": "2.0",
            "method": "textDocument/hover",
            "params": [
                "position": ["character": 32, "line": 3],
                "textDocument": ["uri": uri],
            ],
        ])
        let hoverMessage = try #require(hoverResponse.outgoingMessages.first)
        let hoverResult = try #require(hoverMessage["result"] as? [String: Any])
        let hoverContents = try #require(hoverResult["contents"] as? [String: String])
        #expect(hoverContents["value"]?.contains("spawn(components)") == true)
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
        #expect(capabilities["hoverProvider"] as? Bool == true)
        #expect(capabilities["semanticTokensProvider"] != nil)
        #expect(capabilities["signatureHelpProvider"] != nil)
    }

    private static let systemSource = """
        @system(id: "commands")
        class CommandsSystem {
            func update(context) {
                context.world.commands.spawn([]);
            }
        }
        """
}
