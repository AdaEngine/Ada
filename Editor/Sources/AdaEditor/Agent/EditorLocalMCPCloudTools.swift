#if os(macOS) || os(Windows)
import Foundation

extension EditorLocalMCPSettings {
    private struct ToolBinding: Sendable {
        let serverID: UUID
        let serverName: String
        let connection: Connection
        let tool: EditorLocalMCPTool

        var approvalTarget: String { [serverName, tool.id].joined(separator: " · ") }

        var summary: EditorCloudValue {
            var fields: EditorCloudValue = ["tool": .string(tool.alias), "server": .string(serverName), "name": .string(tool.id),
                                          "description": .string(tool.description)]
            if (try? JSONEncoder().encode(fields).count).map({ $0 <= 640 }) != true {
                fields["description"] = ""
            }
            return fields
        }
    }

    /// Build a catalog for this turn. Newly selected or reconnected tools take effect on the next turn.
    func cloudTools(
        preset: [EditorCloudAgentTool] = [],
        isCurrentProject: @escaping @Sendable () async -> Bool,
        mayInvoke: @escaping @Sendable () async -> Bool = { true }
    ) -> [EditorCloudAgentTool] {
        let bindings = snapshot()
        guard !bindings.isEmpty else { return preset }
        let presetList = preset.first { $0.name == "editor_external_list" }
        let presetDescribe = preset.first { $0.name == "editor_external_describe" }
        let presetInvoke = preset.first { $0.name == "editor_external_invoke" }
        return [
            .init(name: "editor_external_list", definition: [:], readOnly: true, invoke: { input in
                guard await isCurrentProject() else { throw Failure.selection }
                var items = await self.discoverSelected(bindings)
                if let presetList {
                    let response = try await presetList.invoke(input)
                    items += (try JSONDecoder().decode(EditorCloudValue.self, from: Data(response.utf8)))["tools"].array
                }
                return try EditorAgentToolEncoding.string(EditorLocalMCPTool.encode(["tools": .array(items)]))
            }),
            .init(name: "editor_external_describe", definition: [:], readOnly: true, invoke: { input in
                guard await isCurrentProject() else { throw Failure.selection }
                if let alias = input["tool"].string, let binding = bindings[alias], await self.isCurrent(binding) {
                    return try EditorAgentToolEncoding.string(EditorLocalMCPTool.encode(binding.tool.detail(serverName: binding.serverName)))
                }
                guard let presetDescribe, input["tool"].string?.hasPrefix("mcp.") != true else { throw Failure.selection }
                return try await presetDescribe.invoke(input)
            }),
            .init(name: "editor_external_invoke", definition: [:], readOnly: false, invoke: { input in
                guard await isCurrentProject(), await mayInvoke() else { throw Failure.selection }
                if let alias = input["tool"].string, let binding = bindings[alias] {
                    return try await self.invoke(binding, input: input["input"], isCurrentProject: {
                        guard await isCurrentProject() else { return false }
                        return await mayInvoke()
                    })
                }
                guard let presetInvoke, input["tool"].string?.hasPrefix("mcp.") != true else { throw Failure.selection }
                return try await presetInvoke.invoke(input)
            }, validate: { input in
                if let alias = input["tool"].string, let schema = bindings[alias]?.tool.schema {
                    try schema.validate(input["input"])
                } else {
                    guard let presetInvoke, input["tool"].string?.hasPrefix("mcp.") != true else { throw Failure.selection }
                    try presetInvoke.validate?(input)
                }
            }, approvalTarget: { input in
                guard let alias = input["tool"].string else { return nil }
                return bindings[alias]?.approvalTarget ?? presetInvoke?.approvalTarget?(input)
            }, approvalDetails: { input in
                guard let alias = input["tool"].string, bindings[alias] != nil else { return try presetInvoke?.approvalDetails?(input) }
                return try EditorLocalMCPTool.inputDetails(input["input"])
            })
        ]
    }

    private func snapshot() -> [String: ToolBinding] {
        var bindings: [String: ToolBinding] = [:]
        for server in servers {
            guard let connection = connections[server.id] else { continue }
            for tool in connection.tools where isSelected(tool, server: server.id) {
                bindings[tool.alias] = ToolBinding(serverID: server.id, serverName: server.name, connection: connection, tool: tool)
            }
        }
        return bindings
    }

    private func discoverSelected(_ bindings: [String: ToolBinding]) -> [EditorCloudValue] {
        bindings.values.filter(isCurrent).sorted { ($0.serverName, $0.tool.id) < ($1.serverName, $1.tool.id) }.map(\.summary)
    }

    private func isCurrent(_ binding: ToolBinding) -> Bool {
        let current = connections[binding.serverID]
        return current?.id == binding.connection.id && current?.selection == binding.connection.selection && isSelected(binding.tool, server: binding.serverID)
    }

    private func invoke(_ binding: ToolBinding, input: EditorCloudValue, isCurrentProject: @escaping @Sendable () async -> Bool) async throws -> String {
        try Task.checkCancellation()
        guard isCurrent(binding), let schema = binding.tool.schema else { throw Failure.selection }
        try schema.validate(input)
        let connection = binding.connection
        let authorize: @Sendable () async -> Bool = {
            guard await isCurrentProject() else { return false }
            return await self.isCurrent(binding)
        }
        do {
            let tools = try EditorLocalMCPTool.discover(await connection.server.tools(expectedRevision: connection.revision), server: binding.serverID)
            guard tools.contains(where: { $0.id == binding.tool.id && $0.fingerprint == binding.tool.fingerprint }) else {
                await invalidate(binding.serverID, connection: connection.id, reason: Failure.changed.localizedDescription)
                throw Failure.changed
            }
            guard await authorize() else { throw Failure.selection }
            let reply = try await connection.server.call(binding.tool.id, arguments: input, expectedRevision: connection.revision, authorize: authorize)
            try Task.checkCancellation()
            guard await authorize() else { throw Failure.selection }
            return try EditorLocalMCPTool.boundedResult(reply)
        } catch let failure as EditorLocalMCPConnection.Failure {
            throw Failure.transport(failure)
        }
    }
}
#endif
