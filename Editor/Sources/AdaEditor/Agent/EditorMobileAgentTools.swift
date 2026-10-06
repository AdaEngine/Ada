import Foundation
import MCP

struct EditorMobileAgentToolResult: Sendable {
    let ok: Bool
    let payload: String
}

enum EditorAgentToolEncoding {
    static func string(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}

/// The same inventory is used for provider advertisement and project-scoped dispatch.
enum EditorMobileAgentTools {
    static func tools() -> [Tool] {
        let path: Value = .object(["type": "string", "description": "Project-relative file path."])
        let position: [String: Value] = [
            "path": path,
            "line": .object(["type": "integer", "minimum": 0]),
            "character": .object(["type": "integer", "minimum": 0, "description": "Zero-based UTF-16 column."]),
        ]
        return [
            tool("editor.project.context", "Read project configuration, runtime capabilities, and available debugging tools."),
            tool("editor.gravity.diagnostics", "Analyze current AdaScript files with the embedded project-aware Gravity LSP. Omit path to check all project sources.", ["path": path]),
            tool("editor.gravity.completion", "Get AdaScript LSP completions at a zero-based UTF-16 position.", position, ["path", "line", "character"]),
            tool("editor.gravity.hover", "Read AdaScript LSP symbol documentation.", position, ["path", "line", "character"]),
            tool("editor.gravity.definition", "Resolve AdaScript symbols across project files.", position, ["path", "line", "character"]),
            tool(
                "editor.project.configure",
                "Update runtime.entry, runtime.plugins and inputActions using a validated JSON patch. Rejects other keys and invalid settings.",
                ["settingsJSON": .object(["type": "string"])],
                ["settingsJSON"],
                readOnly: false
            ),
            tool(
                "editor.scene.validate",
                "Compile AdaScript and load every project scene, reporting unknown components, invalid payloads, nested-scene and UI-binding errors.",
                ["path": path]
            ),
            tool(
                "editor.runtime.start",
                "Build and start an isolated simulation using real AdaScript, scene, input and physics systems. This does not render or verify touch UI.",
                readOnly: false
            ),
            tool(
                "editor.runtime.step",
                "Advance the isolated simulation and inspect its entities/errors. keys is the full held keyboard set; [] releases all keys. Rebuild/restart after edits.",
                [
                    "frames": .object(["type": "integer", "minimum": 1, "maximum": 120]),
                    "deltaTime": .object(["type": "number", "exclusiveMinimum": 0, "maximum": 0.1]),
                    "keys": .object([
                        "type": "array", "items": .object(["type": "string"]), "description": "Key names such as w, d, space, arrowLeft, arrowRight; omit to keep the previous set.",
                    ]),
                ],
                readOnly: false
            ),
            tool("editor.runtime.inspect", "Read simulation entity transforms, runtime component values, script and scene-navigation errors, and frame count."),
            tool("editor.runtime.stop", "Stop the isolated simulation and cancel its script tasks.", readOnly: false),
            tool(
                "editor.play.start",
                "Build and present the real game in the mobile Play screen. Read editor.output.read for current game errors; interactive touch/visual checks require the visible game.",
                readOnly: false
            ),
            tool("editor.play.inspect", "Read the current visible Play game's script diagnostics."),
            tool("editor.play.capture", "Capture the next completed frame from visible Play as a project PNG. Use editor.image.read to visually inspect it.", readOnly: false),
            tool(
                "editor.output.read",
                "Read bounded build/debug output by cursor, plus current errors from the visible Play runtime.",
                ["after": .object(["type": "integer", "minimum": 0])]
            ),
        ] + EditorAgentKnowledgeTools.tools() + EditorAgentAssetTools.tools() + EditorAgentWebTools.tools()
    }

    static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: Value] = [:],
        _ required: [String] = [],
        readOnly: Bool = true
    ) -> Tool {
        Tool(
            name: name,
            description: description,
            inputSchema: .object([
                "type": "object", "properties": .object(properties),
                "required": .array(required.map(Value.string)), "additionalProperties": false,
            ]),
            annotations: .init(readOnlyHint: readOnly, destructiveHint: false, openWorldHint: false)
        )
    }
}
