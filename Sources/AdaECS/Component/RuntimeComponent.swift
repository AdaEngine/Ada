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
    /// Former names that still resolve to this component.
    public let aliases: [String]
    public let componentID: ComponentId
    public let defaultValues: [ReflectedFieldValue]
    public let fields: [ReflectedComponentField]
    public let name: String
    public let stableID: String

    public init(
        stableID: String,
        name: String,
        aliases: [String] = [],
        fields: [ReflectedComponentField],
        defaultValues: [ReflectedFieldValue]
    ) {
        precondition(!stableID.isEmpty, "Runtime component identifiers must not be empty")
        precondition(fields.count == defaultValues.count, "Runtime component fields and defaults must match")
        self.aliases = aliases
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

    /// Creates reflection metadata for a runtime-defined layout with explicit field kinds.
    ///
    /// Structured kinds (`vector2/3/4`, `color`, `enumeration`, `assetReference`) validate and
    /// normalize written values; scalar kinds keep their exact-type check.
    public init(
        stableID: String,
        name: String,
        aliases: [String] = [],
        fieldNames: [String],
        fieldKinds: [ReflectedFieldKind],
        defaultValues: [ReflectedFieldValue]
    ) {
        precondition(fieldNames.count == defaultValues.count && fieldNames.count == fieldKinds.count, "Runtime component fields, kinds and defaults must match")
        let componentID = ComponentId.runtime(stableID: stableID)
        self.init(
            stableID: stableID,
            name: name,
            aliases: aliases,
            fields: (0..<fieldNames.count).map { index in
                Self.makeField(
                    componentID: componentID,
                    index: index,
                    name: fieldNames[index],
                    defaultValue: defaultValues[index],
                    kind: fieldKinds[index]
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
        defaultValue: ReflectedFieldValue,
        kind explicitKind: ReflectedFieldKind? = nil
    ) -> ReflectedComponentField {
        let kind = explicitKind ?? fieldKind(for: defaultValue)
        let normalize: @Sendable (ReflectedFieldValue) -> ReflectedFieldValue? = { value in
            Self.normalized(value, as: kind, defaultValue: defaultValue)
        }
        let accepts: @Sendable (ReflectedFieldValue) -> Bool = { value in
            normalize(value) != nil
        }
        return unsafe ReflectedComponentField(
            key: name,
            label: name,
            kind: kind,
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
                    let stored = normalize(value)
                else {
                    return nil
                }
                payload.values[index] = stored
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
                    let stored = normalize(value)
                else {
                    return false
                }
                unsafe payload.pointee.values[index] = stored
                return true
            }
        )
    }

    /// Returns the value to store for `value` under `kind`, or `nil` when it is not valid for the field.
    static func normalized(_ value: ReflectedFieldValue, as kind: ReflectedFieldKind, defaultValue: ReflectedFieldValue) -> ReflectedFieldValue? {
        func components(_ allowed: ClosedRange<Int>, pad: Double?) -> ReflectedFieldValue? {
            guard case let .array(items) = value, allowed.contains(items.count) else {
                return nil
            }
            var numbers: [Double] = []
            for item in items {
                switch item {
                case let .double(number) where number.isFinite: numbers.append(number)
                case let .int(number): numbers.append(Double(number))
                default: return nil
                }
            }
            if let pad, numbers.count < allowed.upperBound {
                numbers.append(pad)
            }
            return .array(numbers.map(ReflectedFieldValue.double))
        }
        switch kind {
        case let .optional(wrapped):
            if case .null = value { return .null }
            return normalized(value, as: wrapped, defaultValue: defaultValue)
        case .bool:
            if case .bool = value { return value }
        case .int:
            if case .int = value { return value }
        case .float:
            if case let .double(number) = value, number.isFinite { return value }
        case .string:
            if case .string = value { return value }
        case .vector2: return components(2...2, pad: nil)
        case .vector3: return components(3...3, pad: nil)
        case .vector4: return components(4...4, pad: nil)
        case .color:
            // Stored in the same shape native `Color` fields read, so editors and scripts see one representation.
            let channels = ["red", "green", "blue", "alpha"]
            let numbers: [Double]
            if case let .object(object) = value {
                var found: [Double] = []
                for (index, channel) in channels.enumerated() {
                    switch object[channel] {
                    case let .double(number)? where number.isFinite: found.append(number)
                    case let .int(number)?: found.append(Double(number))
                    case nil where index == 3: found.append(1)
                    default: return nil
                    }
                }
                numbers = found
            } else if case let .array(items)? = components(3...4, pad: 1), items.count == 4 {
                numbers = items.compactMap { item in
                    if case let .double(number) = item { number } else { nil }
                }
            } else {
                return nil
            }
            return .object(Dictionary(uniqueKeysWithValues: zip(channels, numbers.map(ReflectedFieldValue.double))))
        case let .enumeration(cases):
            if case let .string(name) = value, cases.contains(name) { return value }
        case .assetReference:
            switch value {
            case .string, .null: return value
            default: break
            }
        case .readOnly:
            // Legacy shape-driven check: the written value must match the default's case.
            switch (defaultValue, value) {
            case (.bool, .bool), (.int, .int), (.double, .double), (.string, .string): return value
            default: break
            }
        }
        return nil
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
        for alias in descriptor.aliases where idsByName[alias] == nil {
            idsByName[alias] = descriptor.componentID
        }
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
        return storageArchetypes.archetypes[location.archetypeId]
            .chunks.chunks[location.chunkIndex]
            .getRuntimeComponent(componentID, at: location.chunkRow)
    }
}
