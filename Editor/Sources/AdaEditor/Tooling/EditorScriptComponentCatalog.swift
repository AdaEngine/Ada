import AdaEngine
import AdaScriptCompilerCore
import Foundation

/// A script-defined `@component` made available to the Editor inspector and scene loader.
struct EditorScriptDataComponent: @unchecked Sendable {
    let descriptor: EditorComponentDescriptor
    let runtime: RuntimeComponentDescriptor
    let schema: AdaScriptDataSchema
}

/// The script data components of the open project.
///
/// Scenes store a component under its stable ID. A former name or alias still resolves, so a
/// rename never orphans saved data; `AdaScriptSceneSchemaResolver` reports the drift.
final class EditorScriptComponentStore: @unchecked Sendable {
    static let shared = EditorScriptComponentStore()

    private let lock = NSLock()
    private var entries: [EditorScriptDataComponent] = []

    var components: [EditorScriptDataComponent] {
        lock.withLock { entries }
    }

    var schemas: [AdaScriptDataSchema] {
        components.map(\.schema)
    }

    func replace(with components: [EditorScriptDataComponent]) {
        lock.withLock { entries = components }
    }

    /// Resolves a scene key (stable ID, current name, or alias) to its component.
    func component(forKey key: String) -> EditorScriptDataComponent? {
        let entries = components
        guard let resolution = AdaScriptSceneSchemaResolver.resolve(key: key, in: entries.map(\.schema)) else {
            return nil
        }
        return entries.first { $0.schema.id == resolution.schema.id }
    }
}

enum EditorScriptComponentCatalog {
    static func makeComponents(from schemas: [AdaScriptDataSchema]) -> [EditorScriptDataComponent] {
        schemas.filter { $0.kind == .component }.map(makeComponent)
    }

    private static func makeComponent(_ schema: AdaScriptDataSchema) -> EditorScriptDataComponent {
        let runtime = RuntimeComponentDescriptor(
            stableID: schema.id,
            name: schema.name,
            aliases: schema.aliases,
            fieldNames: schema.fields.map(\.name),
            fieldKinds: schema.fields.map { ReflectedFieldKind(editorKind: $0.defaultValue.editorFieldKind) },
            defaultValues: schema.fields.map(\.defaultValue.reflectedValue)
        )
        let defaults = Dictionary(uniqueKeysWithValues: schema.fields.map { ($0.name, $0.defaultValue.editorSceneValue) })
        let descriptor = EditorComponentDescriptor(
            typeName: schema.id,
            displayName: schema.name,
            category: "Script",
            description: "AdaScript component \(schema.name) (\(schema.id)).",
            requiredComponentTypeNames: [],
            fields: schema.fields.map { field in
                var editorField = EditorComponentField(key: field.name, label: field.name, kind: field.defaultValue.editorFieldKind)
                editorField.defaultValue = field.defaultValue.editorSceneValue
                editorField.groupPath = field.groupPath
                return editorField
            },
            makeDefaultPayload: { defaults },
            decode: { payload in try decode(payload, as: runtime) }
        )
        return EditorScriptDataComponent(descriptor: descriptor, runtime: runtime, schema: schema)
    }

    /// Builds a runtime payload, validating every field through its reflected kind.
    static func decode(_ payload: EditorComponentPayload, as runtime: RuntimeComponentDescriptor) throws -> RuntimeComponentPayload {
        var component = runtime.makeDefault()
        for field in runtime.fields {
            guard let saved = payload[field.key] else {
                continue
            }
            guard
                let value = reflected(saved, as: field.kind),
                let updated = field.write(component, value) as? RuntimeComponentPayload
            else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "Invalid value for '\(runtime.name).\(field.key)'")
                )
            }
            component = updated
        }
        return component
    }

    private static func reflected(_ value: EditorSceneValue, as kind: ReflectedFieldKind) -> ReflectedFieldValue? {
        switch kind {
        case let .optional(wrapped):
            if case .null = value { return .null }
            return reflected(value, as: wrapped)
        case .float:
            // Scene encoders may spell integral floating-point values without a decimal point.
            switch value {
            case let .int(number): return .double(Double(number))
            case let .uint(number): return .double(Double(number))
            default: return reflected(value)
            }
        default:
            return reflected(value)
        }
    }

    private static func reflected(_ value: EditorSceneValue) -> ReflectedFieldValue? {
        switch value {
        case .null: .null
        case let .bool(value): .bool(value)
        case let .int(value): .int(value)
        case let .uint(value): Int(exactly: value).map(ReflectedFieldValue.int)
        case let .double(value): .double(value)
        case let .string(value): .string(value)
        case let .array(values):
            values.allSatisfy { reflected($0) != nil } ? .array(values.compactMap(reflected)) : nil
        case let .object(values):
            values.allSatisfy { reflected($1) != nil } ? .object(values.compactMapValues(reflected)) : nil
        }
    }
}

private extension ReflectedFieldKind {
    init(editorKind: EditorComponentFieldKind) {
        switch editorKind {
        case .bool: self = .bool
        case .int: self = .int
        case .float: self = .float
        case .string: self = .string
        case let .enumeration(cases): self = .enumeration(cases)
        case .vector2: self = .vector2
        case .vector3: self = .vector3
        case .vector4: self = .vector4
        case .color: self = .color
        case .assetReference: self = .assetReference
        case .sceneReference, .readOnly: self = .readOnly
        }
    }
}
