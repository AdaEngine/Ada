import AdaUtils
import Foundation

/// A memory-safe carrier used by components whose logical type is defined at runtime.
public struct RuntimeComponentPayload: Component, Sendable {
    public let componentID: ComponentId
    public let stableID: String
    public var values: [ReflectedFieldValue]

    public init(
        componentID: ComponentId,
        stableID: String,
        values: [ReflectedFieldValue]
    ) {
        self.componentID = componentID
        self.stableID = stableID
        self.values = values
    }
}

/// Metadata for one logical runtime component type.
public struct RuntimeComponentDescriptor: Sendable {
    public let componentID: ComponentId
    public let defaultValues: [ReflectedFieldValue]
    public let fields: [ReflectedComponentField]
    public let name: String
    public let stableID: String

    public init(
        stableID: String,
        name: String,
        fields: [ReflectedComponentField],
        defaultValues: [ReflectedFieldValue]
    ) {
        precondition(!stableID.isEmpty, "Runtime component identifiers must not be empty")
        precondition(fields.count == defaultValues.count, "Runtime component fields and defaults must match")
        self.componentID = ComponentId.runtime(stableID: stableID)
        self.defaultValues = defaultValues
        self.fields = fields
        self.name = name
        self.stableID = stableID
    }

    /// Creates reflection metadata for a runtime-defined value layout.
    public init(
        stableID: String,
        name: String,
        fieldNames: [String],
        defaultValues: [ReflectedFieldValue]
    ) {
        precondition(fieldNames.count == defaultValues.count, "Runtime component fields and defaults must match")
        let componentID = ComponentId.runtime(stableID: stableID)
        self.init(
            stableID: stableID,
            name: name,
            fields: zip(fieldNames.indices, zip(fieldNames, defaultValues)).map { index, field in
                Self.makeField(
                    componentID: componentID,
                    index: index,
                    name: field.0,
                    defaultValue: field.1
                )
            },
            defaultValues: defaultValues
        )
    }

    public func makeDefault() -> RuntimeComponentPayload {
        RuntimeComponentPayload(
            componentID: componentID,
            stableID: stableID,
            values: defaultValues
        )
    }

    private static func makeField(
        componentID: ComponentId,
        index: Int,
        name: String,
        defaultValue: ReflectedFieldValue
    ) -> ReflectedComponentField {
        let accepts: @Sendable (ReflectedFieldValue) -> Bool = { value in
            switch (defaultValue, value) {
            case (.bool, .bool), (.int, .int), (.double, .double), (.string, .string): true
            default: false
            }
        }
        return unsafe ReflectedComponentField(
            key: name,
            label: name,
            kind: fieldKind(for: defaultValue),
            isWritable: true,
            accepts: accepts,
            read: { component in
                guard
                    let payload = component as? RuntimeComponentPayload,
                    payload.componentID == componentID,
                    payload.values.indices.contains(index)
                else {
                    return nil
                }
                return payload.values[index]
            },
            write: { component, value in
                guard
                    var payload = component as? RuntimeComponentPayload,
                    payload.componentID == componentID,
                    payload.values.indices.contains(index),
                    accepts(value)
                else {
                    return nil
                }
                payload.values[index] = value
                return payload
            },
            readPointer: { pointer in
                let payload = unsafe pointer.assumingMemoryBound(to: RuntimeComponentPayload.self).pointee
                guard payload.componentID == componentID, payload.values.indices.contains(index) else {
                    return nil
                }
                return payload.values[index]
            },
            writePointer: { pointer, value in
                let payload = unsafe pointer.assumingMemoryBound(to: RuntimeComponentPayload.self)
                guard
                    unsafe payload.pointee.componentID == componentID,
                    unsafe payload.pointee.values.indices.contains(index),
                    accepts(value)
                else {
                    return false
                }
                unsafe payload.pointee.values[index] = value
                return true
            }
        )
    }

    private static func fieldKind(for value: ReflectedFieldValue) -> ReflectedFieldKind {
        switch value {
        case .bool: .bool
        case .int: .int
        case .double: .float
        case .string: .string
        case .array, .null, .object: .readOnly
        }
    }
}

extension ComponentId {
    /// Creates a deterministic process-local ID in a namespace disjoint from native metatype IDs.
    public static func runtime(stableID: String) -> Self {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in stableID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        var processID = UInt(truncatingIfNeeded: hash)
        processID |= UInt(1) << (UInt.bitWidth - 1)
        return Self(id: Int(bitPattern: processID))
    }
}

@inline(__always)
func componentIdentifier(of component: any Component) -> ComponentId {
    if let runtime = component as? RuntimeComponentPayload {
        return runtime.componentID
    }
    return type(of: component).identifier
}

struct RuntimeComponentsStorage: Sendable {
    private var descriptorsByID: [ComponentId: RuntimeComponentDescriptor] = [:]
    private var idsByName: [String: ComponentId] = [:]

    mutating func register(_ descriptor: RuntimeComponentDescriptor) {
        if let existing = descriptorsByID[descriptor.componentID] {
            precondition(existing.stableID == descriptor.stableID, "Runtime component ID collision")
        }
        descriptorsByID[descriptor.componentID] = descriptor
        idsByName[descriptor.name] = descriptor.componentID
        idsByName[descriptor.stableID] = descriptor.componentID
    }

    func descriptor(id: ComponentId) -> RuntimeComponentDescriptor? {
        descriptorsByID[id]
    }

    func descriptor(named name: String) -> RuntimeComponentDescriptor? {
        idsByName[name].flatMap { descriptorsByID[$0] }
    }
}

extension World {
    /// Registers one logical runtime component schema in this world.
    public func registerRuntimeComponent(_ descriptor: RuntimeComponentDescriptor) {
        runtimeComponents.register(descriptor)
    }

    public func runtimeComponentDescriptor(named name: String) -> RuntimeComponentDescriptor? {
        runtimeComponents.descriptor(named: name)
    }

    public func runtimeComponentDescriptor(id: ComponentId) -> RuntimeComponentDescriptor? {
        runtimeComponents.descriptor(id: id)
    }

    public func getRuntimeComponent(
        _ componentID: ComponentId,
        from entity: Entity.ID
    ) -> RuntimeComponentPayload? {
        guard let location = entities.entities[entity] else {
            return nil
        }
        return archetypes.archetypes[location.archetypeId]
            .chunks.chunks[location.chunkIndex]
            .getRuntimeComponent(componentID, at: location.chunkRow)
    }
}
