#if os(iOS)
    import Foundation
    import MCP
    import Protocols
    import SloppyRuntime

    enum MobileEditorAgentToolBridge {
        static func definitions() throws -> [SloppyHostToolDefinition] {
            try EditorMobileAgentTools.tools().map { tool in
                try SloppyHostToolDefinition(
                    name: tool.name,
                    description: tool.description ?? "",
                    inputSchemaJSON: EditorAgentToolEncoding.string(JSONEncoder().encode(tool.inputSchema))
                )
            }
        }

        @MainActor
        static func invoke(_ request: ToolInvocationRequest, service: EditorMobileAgentToolService) async -> ToolInvocationResult {
            do {
                let arguments = try JSONDecoder().decode([String: Value].self, from: JSONEncoder().encode(request.arguments))
                let value = await service.handle(name: request.tool, arguments: arguments)
                let data = try JSONDecoder().decode(JSONValue.self, from: Data(value.payload.utf8))
                return ToolInvocationResult(
                    tool: request.tool,
                    ok: value.ok,
                    data: data,
                    error: value.ok ? nil : ToolErrorPayload(code: "editor_tool_failed", message: value.payload, retryable: false)
                )
            } catch {
                return ToolInvocationResult(tool: request.tool, ok: false, error: ToolErrorPayload(code: "invalid_tool_payload", message: error.localizedDescription, retryable: false))
            }
        }
    }
#endif
