import AdaECS
import AdaUI

/// Publishes detached exported script fields after gameplay updates. AdaUI observes the context on its next refresh.
@PlainSystem(dependencies: [.after(ScriptComponentUpdateSystem.self)])
public struct ScriptUIBindingSystem {
    @Query<UIComponent, ScriptableComponents>
    private var components

    @FilterQuery<UIComponent, Without<ScriptableComponents>>
    private var unboundComponents

    @Query<CompanionPanel, ScriptableComponents>
    private var companionPanels

    @FilterQuery<CompanionPanel, Without<ScriptableComponents>>
    private var unboundCompanionPanels

    public init(world _: World) {}

    @MainActor
    public func update(context _: UpdateContext) {
        components.forEach { ui, scripts in Self.synchronize(ui, scripts: scripts) }
        unboundComponents.forEach { ui in Self.synchronize(ui, scripts: nil) }
        companionPanels.forEach { panel, scripts in Self.synchronize(panel.ui, scripts: scripts) }
        unboundCompanionPanels.forEach { panel in Self.synchronize(panel.ui, scripts: nil) }
    }

    @MainActor
    private static func synchronize(_ ui: UIComponent, scripts: ScriptableComponents?) {
        ui.synchronizeScriptBindings(
            read: { mapping in
                let script = try Self.target(mapping, in: scripts)
                guard let value = script.readExportedField(mapping.field) else {
                    throw UIDiagnostic("Field '\(mapping.script).\(mapping.field)' is not exported for UI binding.")
                }
                return UIScriptFieldSnapshot(owner: ObjectIdentifier(script), value: UIValue(exportedField: value))
            },
            write: { mapping, value in
                let script = try Self.target(mapping, in: scripts)
                guard script.writeExportedField(mapping.field, value: value.exportedField) else {
                    throw UIDiagnostic("Cannot write UI value to '\(mapping.script).\(mapping.field)'. Check the field type.")
                }
            }
        )
    }

    private static func target(_ mapping: UIScriptFieldBinding, in components: ScriptableComponents?) throws -> ScriptableObject {
        var match: ScriptableObject?
        for script in components?.scripts ?? [] {
            let descriptor = ScriptableObjectRegistry.descriptor(for: script)
            if descriptor?.identifier == mapping.script || descriptor?.aliases.contains(mapping.script) == true {
                guard match == nil else {
                    throw UIDiagnostic("More than one attached script matches '\(mapping.script)'.")
                }
                match = script
            }
        }
        guard let script = match else {
            throw UIDiagnostic("Expected one attached script '\(mapping.script)', found 0.")
        }
        return script
    }
}

extension UIValue {
    init(exportedField value: EditorFieldValue) {
        switch value {
        case .null: self = .null
        case let .bool(value): self = .bool(value)
        case let .int(value): self = .number(Double(value))
        case let .double(value): self = .number(value)
        case let .string(value): self = .string(value)
        case let .array(values): self = .array(values.map { UIValue(exportedField: $0) })
        case let .object(values): self = .object(values.mapValues { UIValue(exportedField: $0) })
        }
    }

    var exportedField: EditorFieldValue {
        switch self {
        case .null: .null
        case let .bool(value): .bool(value)
        case let .number(value): .double(value)
        case let .string(value): .string(value)
        case let .array(values): .array(values.map(\.exportedField))
        case let .object(values): .object(values.mapValues(\.exportedField))
        }
    }
}
