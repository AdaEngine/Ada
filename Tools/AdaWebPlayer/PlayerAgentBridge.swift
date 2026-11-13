import AdaA2UI
import AdaAssets
import AdaEngine
import AdaScriptCompilerCore
import AdaScripting
import AdaUIDescription
import Foundation
#if os(WASI)
import JavaScriptKit
#endif

/// Fixed host tools: no filesystem, network or credentials are exposed to generator scripts.
@MainActor
final class PlayerAgentBridge {
    var runtimeDiagnostics: (() -> [String])?
    var gameInput: PlayerGameInput?
    #if os(WASI)
    private var callback: JSClosure?
    #endif

    func install() {
        #if os(WASI)
        guard JSObject.global["__adaStudioPreview"].boolean == true else { return }
        let handler = JSClosure { [weak self] values in
            let input = values.first?.string ?? "{}"
            let result = MainActor.assumeIsolated { self?.execute(input) ?? "{\"error\":\"Host closed\"}" }
            return .string(result)
        }
        callback = handler
        JSObject.global["__adaStudioTool"] = handler.jsValue
        #endif
    }

    func execute(_ input: String) -> String {
        do {
            guard input.utf8.count <= 1_048_576,
                  let fields = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
                  let name = fields["name"] as? String else {
                throw Failure("Invalid tool request")
            }
            let result = try run(name, fields)
            return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
        } catch {
            let value = ["error": String(describing: error)]
            return (try? String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self)) ?? "{}"
        }
    }

    private func run(_ name: String, _ fields: [String: Any]) throws -> [String: Any] {
        if name == "capabilities" { return ["runtimeAPI": 4, "agentToolsVersion": 2, "sourceSchemas": true] }
        if name == "validate-component-values" { return try validateComponentValues(fields) }
        if name == "runtime-diagnostics" { return ["diagnostics": Array((runtimeDiagnostics?() ?? []).suffix(30))] }
        if name == "game-input" {
            guard let key = fields["key"] as? String, let down = fields["down"] as? Bool, let gameInput else { throw Failure("Gameplay input unavailable") }
            try gameInput.send(key: key, down: down)
            return ["ok": true]
        }
        if name == "inspect-sources" {
            guard let input = fields["sources"] as? [[String: String]], input.count <= 512 else { throw Failure("Expected at most 512 AdaScript source files") }
            var names = Set<String>()
            let sources = try input.map { item -> AdaScriptCompilerSource in
                guard let path = item["path"], path.hasPrefix("Sources/"), path.hasSuffix(".ada"),
                      !path.split(separator: "/").contains(".."), names.insert(path).inserted,
                      let source = item["source"], source.utf8.count <= 512 * 1024 else { throw Failure("Invalid AdaScript source path or size") }
                return AdaScriptCompilerSource(path: path, source: source)
            }
            guard let value = try JSONSerialization.jsonObject(with: AdaScriptAgentSchemaCatalog.encoded(sources: sources)) as? [String: Any] else { throw Failure("Invalid schema catalog") }
            return value
        }
        if name == "api-describe" {
            let query = (fields["query"] as? String ?? "").lowercased()
            let environment = AdaScriptTypeEnvironment.standard
            let types = environment.members.keys.sorted().filter { query.isEmpty || $0.lowercased().contains(query) }
            return ["source": "Linked AdaScript compiler type environment", "types": types.prefix(30).map { type in
                ["name": type, "members": (environment.members[type] ?? [:]).sorted { $0.key < $1.key }.map { name, member in
                    ["name": name, "type": member.type.displayName, "description": member.detail ?? "", "insertText": member.insertText ?? name]
                }] as [String: Any]
            }]
        }
        if name == "a2ui-export" {
            guard let surface = fields["surface"] as? [String: Any], let id = surface["id"] as? String,
                  let components = surface["components"] as? [[String: Any]], let model = surface["data"] as? [String: Any] else {
                throw Failure("Invalid UI surface")
            }
            let client = A2UIClient()
            let envelopes: [[String: Any]] = [
                ["version": "v0.9.1", "createSurface": ["surfaceId": id, "catalogId": A2UIClient.catalogID]],
                ["version": "v0.9.1", "updateComponents": ["surfaceId": id, "components": components]],
                ["version": "v0.9.1", "updateDataModel": ["surfaceId": id, "value": model]]
            ]
            for envelope in envelopes { try client.receive(JSONSerialization.data(withJSONObject: envelope)) }
            guard let view = client.surfaces[id] else { throw Failure("Surface not created") }
            return ["content": try view.snapshot().encodedYAML()]
        }
        guard let source = fields["source"] as? String, source.utf8.count <= 65_536 else { throw Failure("Missing generator source (maximum 64 KiB)") }
        let data: Data
        switch name {
        case "editor_sprite_generate":
            let result = try AdaScriptSpriteGenerator.generate(source: source)
            data = try PNGWriter().encode(width: result.canvas.width, height: result.canvas.height, rgba: result.canvas.rgba())
        case "editor_audio_generate":
            data = try WAVWriter().encode(AdaScriptSoundGenerator.generate(source: source))
        case "editor_model_generate":
            data = try GLBWriter().encode(AdaScriptModelGenerator.generate(source: source))
        case "editor_voxel_generate":
            let result = try AdaScriptVoxelGenerator.generate(source: source)
            data = try VOXWriter().encode(model: result.model, palette: result.palette)
        default: throw Failure("Unavailable host tool: " + name)
        }
        guard data.count <= 16 * 1024 * 1024 else { throw Failure("Generated asset exceeds 16 MiB") }
        return ["data": data.base64EncodedString(), "bytes": data.count]
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Decode complex values with the same native codecs as scene loading, without
    /// creating textures, worlds, scripts or gameplay systems. JSON is carried as
    /// text so JavaScript cannot round native 64-bit masks before decoding.
    private func validateComponentValues(_ fields: [String: Any]) throws -> [String: Any] {
        guard let components = fields["components"] as? [[String: String]], components.count <= 4096 else {
            throw Failure("Expected component payloads")
        }
        var diagnostics: [[String: String]] = []
        for item in components {
            guard let name = item["typeName"], let text = item["payloadJSON"], let entity = item["entityID"] else { throw Failure("Missing component payload") }
            let data = Data(text.utf8)
            do {
                switch name {
                case "AdaPhysics.PhysicsBody2DComponent": _ = try JSONDecoder().decode(PhysicsBody2DComponent.self, from: data)
                case "AdaScene.PointLightComponent": _ = try JSONDecoder().decode(PointLightComponent.self, from: data)
                case "AdaRender.Environment3D", "AdaCorePipelines.Environment3D": _ = try JSONDecoder().decode(Environment3D.self, from: data)
                case "AdaSprite.Sprite":
                    struct SpriteValues: Decodable { let anchor: SpriteAnchor; let imageMode: SpriteImageMode }
                    _ = try JSONDecoder().decode(SpriteValues.self, from: data)
                default: throw Failure("Unsupported native preflight component: " + name)
                }
            } catch {
                let context: DecodingError.Context?
                switch error {
                case let DecodingError.dataCorrupted(value), let DecodingError.keyNotFound(_, value),
                     let DecodingError.typeMismatch(_, value), let DecodingError.valueNotFound(_, value): context = value
                default: context = nil
                }
                let field = context?.codingPath.map(\.stringValue).joined(separator: ".") ?? ""
                diagnostics.append(["entityID": entity, "component": name,
                    "path": "entities.\(entity).components.\(name)" + (field.isEmpty ? "" : "." + field),
                    "message": String(describing: error), "repairTool": "editor_components_describe"])
            }
        }
        return ["valid": diagnostics.isEmpty, "diagnostics": diagnostics]
    }
}
