import AdaEngine
import Foundation

@MainActor
final class EditorStudioPluginTurn {
    private struct Binding {
        let definition: EditorStudioToolDefinition
        let action: EditorStudioPluginManifest.Action
        let input: EditorLocalMCPToolSchema
        let output: EditorLocalMCPToolSchema
        let grant: UUID
    }

    private struct Entity {
        let plugin: String
        let identifier: String
    }

    private static let searchInput: EditorCloudValue = [
        "type": "object", "additionalProperties": false, "required": ["query"],
        "properties": ["query": ["type": "string", "maxLength": 120], "store": ["type": "string", "enum": ["fab", "unity"]]]
    ]

    private static let entitySchema: EditorCloudValue = [
        "type": "object", "additionalProperties": false, "required": ["asset", "name", "store", "localFile"],
        "properties": [
            "asset": ["type": "string", "maxLength": 36], "name": ["type": "string", "maxLength": 480],
            "store": ["type": "string", "enum": ["fab", "unity"]], "localFile": ["type": "boolean"]
        ]
    ]

    private static let searchOutput: EditorCloudValue = [
        "type": "object", "additionalProperties": false, "required": ["assets"],
        "properties": ["assets": ["type": "array", "maxItems": 20, "items": entitySchema]]
    ]

    private weak var host: EditorStudioToolHost?
    private let isCurrentWorkspace: @Sendable () async -> Bool
    private let bindings: [String: Binding]
    private var references: [UUID: Entity] = [:]

    init(host: EditorStudioToolHost, isCurrentWorkspace: @escaping @Sendable () async -> Bool) {
        self.host = host
        self.isCurrentWorkspace = isCurrentWorkspace
        var available: [String: Binding] = [:]
        for definition in host.definitions where host.pluginAIIDs.contains(definition.schema.id) && host.pluginDefinitionIsCurrent(definition) {
            guard let grant = host.pluginGrant(id: definition.schema.id) else { continue }
            for action in definition.manifest?.actions ?? [] {
                let inputSchema = action.kind == .assetSearch ? Self.searchInput : action.input
                let outputSchema = action.kind == .assetSearch ? Self.searchOutput : action.output
                guard let inputSchema, let outputSchema,
                      let input = try? EditorLocalMCPToolSchema(inputSchema),
                      let output = try? EditorLocalMCPToolSchema(outputSchema) else { continue }
                available[definition.schema.id + "/" + action.id] = .init(definition: definition, action: action, input: input, output: output, grant: grant)
            }
        }
        bindings = available
    }

    func tools() -> [EditorCloudAgentTool] {
        guard !bindings.isEmpty else {
            return []
        }
        return [
            .init(name: "editor_plugins_list", definition: [:], readOnly: true, invoke: { _ in try await self.list() }),
            .init(name: "editor_plugins_describe", definition: [:], readOnly: true, invoke: { try await self.describe($0["id"].string) }),
            .init(name: "editor_plugins_invoke", definition: [:], readOnly: true, invoke: { try await self.invoke($0["id"].string, input: $0["input"]) })
        ]
    }

    private func list() async throws -> String {
        guard await isCurrentWorkspace() else { throw EditorStudioPluginManifest.Failure.unavailable }
        let entries = bindings.keys.sorted().compactMap { id -> EditorCloudValue? in
            guard let binding = bindings[id], isAllowed(binding) else {
                return nil
            }
            return ["id": .string(id), "kind": .string(binding.action.kind.rawValue), "title": .string(binding.action.title.en)]
        }
        return try Self.encode(["actions": .array(Array(entries.prefix(24)))])
    }

    private func describe(_ id: String?) async throws -> String {
        let binding = try await authorized(id)
        return try Self.encode(["title": .string(binding.action.title.en), "input": binding.input.value, "output": binding.output.value])
    }

    private func invoke(_ id: String?, input: EditorCloudValue) async throws -> String {
        let binding = try await authorized(id)
        try binding.input.validate(input)
        let plugin = binding.definition.schema.id
        var localInput = input
        if let field = binding.action.assetReferenceInput {
            guard let key = input[field].string, let ticket = UUID(uuidString: key), let reference = references[ticket],
                  reference.plugin == plugin else { throw EditorStudioPluginManifest.Failure.unavailable }
            localInput[field] = .string(reference.identifier)
        }
        var result: EditorCloudValue
        switch binding.action.binding {
        case "native_search", "native_details":
            result = try await performLibraryCall(binding.action.binding, input: localInput)
        default:
            let tool = try AdaScriptToolRuntime(sources: binding.definition.sources, schema: binding.definition.schema, grantedPermissions: [], readOnlyTool: true)
            let json = try tool.performReadOnlyTool(binding.action.binding, inputJSON: Self.encode(localInput))
            result = try JSONDecoder().decode(EditorCloudValue.self, from: Data(json.utf8))
        }
        _ = try await authorized(id)
        try binding.output.validate(result)
        if binding.action.kind == .assetSearch {
            result["assets"] = .array(try result["assets"].array.map { try reference($0, plugin: plugin) })
        } else if let field = binding.action.assetReferenceInput, result["asset"] == localInput[field] {
            result["asset"] = input[field]
        }
        return try Self.encode(result)
    }

    private func reference(_ asset: EditorCloudValue, plugin: String) throws -> EditorCloudValue {
        guard let identifier = asset["asset"].string, !identifier.isEmpty, references.count < 1_000 else {
            throw EditorStudioPluginManifest.Failure.unavailable
        }
        let ticket = UUID()
        references[ticket] = Entity(plugin: plugin, identifier: identifier)
        var result = asset
        result["asset"] = .string(ticket.uuidString)
        return result
    }

    private func performLibraryCall(_ action: String, input: EditorCloudValue) async throws -> EditorCloudValue {
        guard let library = host?.externalAssets else { throw EditorStudioPluginManifest.Failure.unavailable }
        if action == "native_details" {
            guard let value = input["asset"].string, let id = UUID(uuidString: value),
                  let item = try await library.listing(id: id) else { throw EditorStudioPluginManifest.Failure.unavailable }
            return await entity(item, library: library)
        }
        let store = input["store"].string.flatMap(EditorExternalAssetLibrary.Store.init(rawValue:))
        let matches = try await library.search(input["query"].string ?? "", store: store)
        var results: [EditorCloudValue] = []
        for item in matches.prefix(20) {
            results.append(await entity(item, library: library))
        }
        return ["assets": .array(results)]
    }

    private func entity(_ item: EditorExternalAssetLibrary.Listing, library: EditorExternalAssetLibrary) async -> EditorCloudValue {
        let local = await library.modelURL(for: item) != nil
        return ["asset": .string(item.id.uuidString), "name": .string(item.title), "store": .string(item.store.rawValue), "localFile": .bool(local)]
    }

    private func authorized(_ id: String?) async throws -> Binding {
        try Task.checkCancellation()
        guard await isCurrentWorkspace(), let id, let binding = bindings[id], isAllowed(binding) else {
            throw EditorStudioPluginManifest.Failure.unavailable
        }
        return binding
    }

    private func isAllowed(_ binding: Binding) -> Bool {
        guard let host, host.pluginGrant(id: binding.definition.schema.id) == binding.grant else {
            return false
        }
        return host.pluginDefinitionIsCurrent(binding.definition)
    }

    private static func encode(_ value: EditorCloudValue) throws -> String {
        try EditorAgentToolEncoding.string(JSONEncoder().encode(value))
    }
}
