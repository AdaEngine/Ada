@_spi(AdaEngine) import AdaEngine
import Foundation

/// Captures real component fields; display summaries alone truncate runtime-defined
/// AdaScript components and cannot establish gameplay invariants.
@MainActor
enum EditorScenarioComponentSnapshot {
    static func read(
        in world: World,
        entity: Entity.ID,
        matching wanted: Set<String>
    ) -> (summaries: [String: String], fields: [String: [String: Any]]) {
        var summaries: [String: String] = [:]
        var fields: [String: [String: Any]] = [:]
        for entry in world.getComponents(for: entity) {
            let short = entry.typeName.split(separator: ".").last.map(String.init) ?? entry.typeName
            var names = [short, entry.typeName]
            let runtime = entry.component as? RuntimeComponentPayload
            let descriptor = runtime.flatMap { world.runtimeComponentDescriptor(id: $0.componentID) }
            if let descriptor { names += [descriptor.stableID, descriptor.name] + descriptor.aliases }
            guard wanted.isEmpty || names.contains(where: { wanted.contains($0.lowercased()) }) else { continue }
            summaries[short] = EditorPlayInspectionModel.summary(of: entry.component, typeName: entry.typeName)
            if let runtime, let descriptor {
                var values: [String: Any] = [:]
                for field in descriptor.fields {
                    if let value = field.read(runtime) { values[field.key] = json(value) }
                }
                fields[descriptor.stableID] = values
            } else if let native = ComponentReflectionRegistry.descriptor(named: entry.typeName) {
                fields[entry.typeName] = native.readPayload(from: entry.component).mapValues(json)
            }
        }
        return (summaries, fields)
    }

    private static func json(_ value: ReflectedFieldValue) -> Any {
        switch value {
        case .null: NSNull()
        case let .bool(value): value
        case let .int(value): value
        case let .double(value): value.isFinite ? value as Any : NSNull()
        case let .string(value): value
        case let .array(values): values.map(json)
        case let .object(values): values.mapValues(json)
        }
    }
}
