@_spi(Scripting) import AdaECS
import Gravity

@GSExportable("AdaAttachedComponent")
final class GravityAttachedComponentView: @unchecked Sendable {
    private let componentType: any Component.Type
    private let descriptor: EditorComponentDescriptor?
    private let entityID: Entity.ID
    private let reportDiagnostic: @Sendable (String) -> Void
    private let virtualMachine: GravityVirtualMachine
    // The VM may retain this bridge; it must never keep a stopped scene alive.
    // Access runs under AdaScriptRuntimeCoordinator; each use retains a local world snapshot.
    private weak var world: World?

    @GSExportableIgnore
    static func make(
        world: World,
        entityID: Entity.ID,
        componentType: any Component.Type,
        descriptor: EditorComponentDescriptor?,
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        virtualMachine: GravityVirtualMachine
    ) -> GravityAttachedComponentView {
        GravityAttachedComponentView(
            world: world,
            entityID: entityID,
            componentType: componentType,
            descriptor: descriptor,
            reportDiagnostic: reportDiagnostic,
            virtualMachine: virtualMachine
        )
    }

    private init(
        world: World,
        entityID: Entity.ID,
        componentType: any Component.Type,
        descriptor: EditorComponentDescriptor?,
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        virtualMachine: GravityVirtualMachine
    ) {
        self.componentType = componentType
        self.descriptor = descriptor
        self.entityID = entityID
        self.reportDiagnostic = reportDiagnostic
        self.virtualMachine = virtualMachine
        self.world = world
    }

    func available() -> Bool {
        world?.has(componentType.identifier, in: entityID) == true
    }

    func get(_ fieldName: String) -> GSValue? {
        guard
            let world, let descriptor,
            let field = descriptor.fields.first(where: { $0.key == fieldName }),
            let component = world.getComponent(named: descriptor.typeName, from: entityID),
            let value = field.read(component)
        else {
            reportDiagnostic("Unknown or unavailable attached component field '\(fieldName)'")
            return nil
        }
        return AnnotatedGravityValueBridge.makeGravityValue(value, virtualMachine: virtualMachine)
    }

    @discardableResult
    func set(_ fieldName: String, _ value: GSValue) -> Bool {
        guard
            let world, let descriptor,
            let fieldValue = AnnotatedGravityValueBridge.makeEditorFieldValue(value),
            descriptor.write(fieldValue, toField: fieldName, in: world, entity: entityID)
        else {
            reportDiagnostic("Invalid attached component field '\(fieldName)'")
            return false
        }
        return true
    }
}

@GSExportable("AdaAttachedResource")
final class GravityAttachedResourceView: @unchecked Sendable {
    private let fields: [String: EditorComponentFieldDescriptor]
    private let optional: Bool
    private let reportDiagnostic: @Sendable (String) -> Void
    private let resourceType: any Resource.Type
    private let virtualMachine: GravityVirtualMachine
    // The VM may retain this bridge; it must never keep a stopped scene alive.
    // Access runs under AdaScriptRuntimeCoordinator; each use retains a local world snapshot.
    private weak var world: World?

    @GSExportableIgnore
    static func make(
        world: World,
        resourceType: any Resource.Type,
        fields: [String: EditorComponentFieldDescriptor],
        optional: Bool,
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        virtualMachine: GravityVirtualMachine
    ) -> GravityAttachedResourceView {
        GravityAttachedResourceView(
            world: world,
            resourceType: resourceType,
            fields: fields,
            optional: optional,
            reportDiagnostic: reportDiagnostic,
            virtualMachine: virtualMachine
        )
    }

    private init(
        world: World,
        resourceType: any Resource.Type,
        fields: [String: EditorComponentFieldDescriptor],
        optional: Bool,
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        virtualMachine: GravityVirtualMachine
    ) {
        self.fields = fields
        self.optional = optional
        self.reportDiagnostic = reportDiagnostic
        self.resourceType = resourceType
        self.virtualMachine = virtualMachine
        self.world = world
    }

    func available() -> Bool {
        world?.getResource(named: String(reflecting: resourceType)) != nil
    }

    func get(_ fieldName: String) -> GSValue? {
        guard
            let world, let field = fields[fieldName],
            let value = world.readResourceField(type: resourceType, field: field)
        else {
            if !optional {
                reportDiagnostic("Unknown or unavailable attached resource field '\(fieldName)'")
            }
            return nil
        }
        return AnnotatedGravityValueBridge.makeGravityValue(value, virtualMachine: virtualMachine)
    }

    @discardableResult
    func set(_ fieldName: String, _ value: GSValue) -> Bool {
        guard
            let world, let field = fields[fieldName],
            let fieldValue = AnnotatedGravityValueBridge.makeEditorFieldValue(value),
            world.writeResourceField(type: resourceType, field: field, value: fieldValue)
        else {
            reportDiagnostic("Invalid attached resource field '\(fieldName)'")
            return false
        }
        return true
    }
}
