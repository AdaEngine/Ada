import AdaA2UI
@_spi(AdaEngine) import AdaEngine
import AdaUIDescription
import Foundation
import MCP

struct EditorAgentA2UIToolResult: Codable, Equatable, Sendable {
    let path: String
    let revision: String
    let changeID: String?
    let message: String
}

/// A small host-owned command vocabulary. Card values are data, never executable code.
@MainActor
struct EditorAgentA2UIToolRequest {
    let name: String
    let context: [String: UIValue]

    init(_ event: A2UIClientEvent) throws {
        guard case let .object(envelope) = event.envelope,
              case let .object(action) = envelope["action"], let name = action["name"]?.string,
              case let .object(context) = action["context"] else {
            throw Failure("The tool button requires an action context.")
        }
        self.name = name
        self.context = context
    }

    static func isLocal(_ event: A2UIClientEvent) -> Bool {
        guard case let .object(envelope) = event.envelope,
              case let .object(action) = envelope["action"], let name = action["name"]?.string else { return false }
        return name.hasPrefix("editor.")
    }

    func string(_ key: String) throws -> String {
        guard let value = context[key]?.string, !value.isEmpty else { throw Failure("Missing tool value: \(key).") }
        return value
    }

    func operations(in model: EditorSceneModel) throws -> [EditorAgentSceneOperation] {
        switch name {
        case "editor.scene.apply":
            guard let values = context["operations"]?.array, !values.isEmpty, values.count <= 100 else {
                throw Failure("Provide 1...100 scene operations.")
            }
            return try values.map {
                let value = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode($0))
                return try EditorAgentMCPTools.shared.decodeOperation(value)
            }
        case "editor.scene.spawn":
            let entityID = try string("entityID")
            guard let count = context["count"]?.number, count.isFinite, (1...100).contains(count), count.rounded() == count,
                  let spacing = context["spacing"]?.number, spacing.isFinite, abs(spacing) <= 100_000,
                  !model.isRootEntity(entityID), model.entities.contains(where: { $0.id == entityID }) else {
                throw Failure("Choose an existing non-root NPC, an integer count from 1 to 100, and finite X spacing within ±100000.")
            }
            var candidate = model
            let originalIDs = Set(model.entities.map(\.id))
            for index in 1...Int(count) {
                guard let clone = candidate.duplicateEntity(entityID), let root = candidate.entities.firstIndex(where: { $0.id == clone.id }) else {
                    throw Failure("This NPC cannot be duplicated.")
                }
                var transform = candidate.entities[root].components[EditorBuiltInComponentType.transform]
                    ?? EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform)
                var position: [EditorSceneValue] = [.double(0), .double(0), .double(0)]
                if case let .array(value) = transform["position"] { position = value }
                guard position.count == 3, let x = position[0].doubleValue else { throw Failure("NPC position is invalid.") }
                position[0] = .double(x + Double(index) * spacing)
                transform["position"] = .array(position)
                candidate.entities[root].components[EditorBuiltInComponentType.transform] = transform
                guard candidate.entities.count - model.entities.count <= 100 else {
                    throw Failure("A spawn batch may create at most 100 entities, including NPC children.")
                }
            }
            let copies = candidate.entities.filter { !originalIDs.contains($0.id) }
            return copies.map {
                .createEntity(id: $0.id, name: $0.name, parentID: $0.parent, components: $0.components)
            } + copies.filter { !$0.enabled }.map { .setEntityEnabled(id: $0.id, enabled: false) }
        case "editor.scene.setColor":
            let entityID = try string("entityID")
            let typeName = try string("typeName")
            let field = try string("field")
            guard let entity = model.entities.first(where: { $0.id == entityID }), var payload = entity.components[typeName],
                  EditorComponentRegistry.descriptor(named: typeName)?.fields.contains(where: { $0.key == field && $0.kind == .color }) == true,
                  let color = EditorUIColorField.color(try string("color")) else {
                throw Failure("Choose an existing color field and a valid color, such as #3366FFFF.")
            }
            payload[field] = .object([
                "red": .double(Double(color.red)), "green": .double(Double(color.green)),
                "blue": .double(Double(color.blue)), "alpha": .double(Double(color.alpha))
            ])
            return [.setComponent(entityID: entityID, typeName: typeName, payload: payload)]
        default:
            throw Failure("Unsupported chat tool: \(name).")
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

extension EditorAgentA2UISession {
    /// Returns true for every reserved editor action, including unsupported ones (fail closed).
    func performLocal(
        _ submission: EditorAgentA2UISubmission,
        apply: (EditorAgentA2UIToolRequest) throws -> EditorAgentA2UIToolResult
    ) -> Bool {
        guard EditorAgentA2UIToolRequest.isLocal(submission.event) else {
            return false
        }
        do {
            let request = try EditorAgentA2UIToolRequest(submission.event)
            if request.name == "editor.color.pick" {
                let binding = try request.string("binding")
                let value = try request.string("value")
                guard let color = EditorUIColorField.color(value) else { throw EditorAgentA2UIToolRequest.Failure("Invalid picker color.") }
                try validateLocalBinding(binding, surfaceID: submission.surfaceID, expected: .string(value))
                #if os(macOS) || os(iOS)
                let generation = client.surfaces[submission.surfaceID]?.generation
                EditorPlatformColorPicker.present(value: .init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)) { [weak self] color in
                    guard let self, self.client.surfaces[submission.surfaceID]?.generation == generation else {
                        return
                    }
                    do {
                        try self.updateLocalValue(.string(color.hexString), binding: binding, surfaceID: submission.surfaceID)
                    } catch { self.setError(error.localizedDescription, surfaceID: submission.surfaceID) }
                }
                completeLocal(surfaceID: submission.surfaceID)
                #else
                throw EditorAgentA2UIToolRequest.Failure("Use the color text field on this platform.")
                #endif
            } else {
                // Validate the writable revision path before committing any scene side effect.
                let binding = try request.string("revisionBinding")
                try validateLocalBinding(binding, surfaceID: submission.surfaceID, expected: .string(try request.string("expectedRevision")))
                let result = try apply(request)
                try updateLocalValue(.string(result.revision), binding: binding, surfaceID: submission.surfaceID)
                completeLocal(surfaceID: submission.surfaceID, result: result, revisionBinding: binding)
            }
        } catch { rejectSubmission(error.localizedDescription, surfaceID: submission.surfaceID) }
        return true
    }

    private func validateLocalBinding(_ binding: String, surfaceID: String, expected: UIValue) throws {
        guard binding.hasPrefix("/"), let surface = client.surfaces[surfaceID] else {
            throw EditorAgentA2UIToolRequest.Failure("The card requires an absolute data binding.")
        }
        // The protocol decoder owns JSON Pointer validation and bound-value type checking.
        let probe = A2UIClient()
        for message in surface.restorationMessages() { try probe.receive(JSONEncoder().encode(message)) }
        let data = try JSONEncoder().encode(UIValue.object([
            "version": .string("v0.9.1"), "updateDataModel": .object([
                "surfaceId": .string(surfaceID), "path": .string(binding), "value": expected
            ])
        ]))
        try probe.receive(data)
        guard probe.surfaces[surfaceID]?.dataModel == surface.dataModel else {
            throw EditorAgentA2UIToolRequest.Failure("The action's revision/color must match its bound card value.")
        }
    }

    func updateLocalValue(_ value: UIValue, binding: String, surfaceID: String) throws {
        try client.receive(JSONEncoder().encode(UIValue.object([
            "version": .string("v0.9.1"), "updateDataModel": .object([
                "surfaceId": .string(surfaceID), "path": .string(binding), "value": value
            ])
        ])))
    }
}
