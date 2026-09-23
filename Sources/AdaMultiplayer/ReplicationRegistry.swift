import AdaApp
import AdaECS
import AdaTransform
import Foundation
import Math

/// Controls whether an authoritative entity is visible to a peer.
public protocol ReplicationPolicy: Sendable {
    func shouldReplicate(entity: NetworkEntityID, to peer: PeerID) -> Bool
}

/// The v1 policy that exposes every replicated entity to every connected peer.
public struct AllPeersReplicationPolicy: ReplicationPolicy {
    public init() {}

    public func shouldReplicate(entity _: NetworkEntityID, to _: PeerID) -> Bool {
        true
    }
}

/// Per-component replication behavior.
public struct ReplicatedComponentOptions<T: Component & Codable & Sendable>: Sendable {
    public var interpolate: (@Sendable (_ previous: T, _ current: T, _ alpha: Float) -> T)?

    public init(
        interpolate: (@Sendable (_ previous: T, _ current: T, _ alpha: Float) -> T)? = nil
    ) {
        self.interpolate = interpolate
    }
}

struct ReplicatedComponentDescriptor: Sendable {
    var schema: NetworkTypeDescriptor
    var typeID: String { schema.typeID }
    var version: UInt16 { schema.version }
    var componentID: ComponentId
    var encode: @Sendable (World, Entity.ID, any NetworkCodec) throws -> Data?
    var apply: @Sendable (Data, World, Entity.ID, any NetworkCodec) throws -> Void
    var remove: @Sendable (World, Entity.ID) -> Void
    var interpolate: (@Sendable (Data, Data, Float, any NetworkCodec) throws -> Data)?
}

/// Registry shared by the multiplayer systems in one world.
public struct MultiplayerRegistry: Resource {
    var replicatedComponentsByTypeID: [String: ReplicatedComponentDescriptor] = [:]
    var replicatedTypeIDByComponentID: [ComponentId: String] = [:]
    var rpcByTypeID: [String: RPCDescriptor] = [:]

    public init() {}

    public var schemaDigest: String {
        let componentEntries = replicatedComponentsByTypeID.values.map {
            "component:\($0.schema.compatibilitySignature)"
        }
        let rpcEntries = rpcByTypeID.values.map {
            if let schema = $0.schema {
                return "rpc:\(schema.compatibilitySignature)"
            }
            return "rpc:\($0.typeID):\($0.version):\($0.kind.rawValue):\($0.direction.rawValue)"
        }
        return Self.fnv1a64((componentEntries + rpcEntries).sorted().joined(separator: "|"))
    }

    mutating func register<T: Component & Codable & Sendable>(
        _ type: T.Type,
        id: String,
        version: UInt16,
        options: ReplicatedComponentOptions<T>,
        schema: NetworkTypeDescriptor? = nil
    ) {
        precondition(!id.isEmpty, "Network component identifier must not be empty")
        precondition(replicatedComponentsByTypeID[id] == nil, "Network component identifier \(id) is already registered")

        let interpolation: (@Sendable (Data, Data, Float, any NetworkCodec) throws -> Data)?
        if let interpolate = options.interpolate {
            interpolation = { previous, current, alpha, codec in
                let lhs: T = try codec.decode(T.self, from: previous)
                let rhs: T = try codec.decode(T.self, from: current)
                return try codec.encode(interpolate(lhs, rhs, alpha))
            }
        } else {
            interpolation = nil
        }

        let descriptor: ReplicatedComponentDescriptor = ReplicatedComponentDescriptor(
            schema: schema ?? NetworkTypeDescriptor(
                typeID: id,
                version: version,
                kind: .component,
                authority: .host,
                fields: []
            ),
            componentID: T.identifier,
            encode: { world, entity, codec in
                guard let component = world.get(T.self, from: entity) else {
                    return nil
                }
                return try codec.encode(component)
            },
            apply: { data, world, entity, codec in
                world.insert(try codec.decode(T.self, from: data), for: entity)
            },
            remove: { world, entity in
                world.remove(T.self, from: entity)
            },
            interpolate: interpolation
        )
        replicatedComponentsByTypeID[id] = descriptor
        replicatedTypeIDByComponentID[T.identifier] = id
    }

    private static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

extension AppWorlds {
    /// Registers a component that is copied for entities carrying
    /// ``ReplicatedEntity``. Registration must happen during plugin setup.
    @discardableResult
    public func registerReplicatedComponent<T: Component & Codable & Sendable>(
        _ type: T.Type,
        id: String,
        version: UInt16 = 1,
        options: ReplicatedComponentOptions<T> = ReplicatedComponentOptions()
    ) -> Self {
        T.registerComponent()
        guard getResource(MultiplayerRegistry.self) != nil else {
            preconditionFailure("Add MultiplayerPlugin before registering network components")
        }
        getRefResource(MultiplayerRegistry.self).wrappedValue.register(
            type,
            id: id,
            version: version,
            options: options
        )
        return self
    }

    /// Registers a component using metadata synthesized by ``ReplicatedComponent``.
    @discardableResult
    public func registerReplicatedComponent<T: NetworkReplicatedComponent>(
        _ type: T.Type,
        options: ReplicatedComponentOptions<T> = ReplicatedComponentOptions()
    ) -> Self {
        let schema = T.networkDescriptor
        T.registerComponent()
        guard getResource(MultiplayerRegistry.self) != nil else {
            preconditionFailure("Add MultiplayerPlugin before registering network components")
        }
        getRefResource(MultiplayerRegistry.self).wrappedValue.register(
            type,
            id: schema.typeID,
            version: schema.version,
            options: options,
            schema: schema
        )
        return self
    }
}

extension MultiplayerRegistry {
    mutating func registerRuntimeComponent(
        _ descriptor: RuntimeComponentDescriptor,
        schema: NetworkTypeDescriptor,
        fieldIndices: [UInt16: Int]
    ) {
        precondition(schema.kind == .component, "Runtime replication schema must describe a component")
        precondition(replicatedComponentsByTypeID[schema.typeID] == nil, "Network component identifier \(schema.typeID) is already registered")
        let replicated = ReplicatedComponentDescriptor(
            schema: schema,
            componentID: descriptor.componentID,
            encode: { world, entity, codec in
                guard let component = world.getRuntimeComponent(descriptor.componentID, from: entity) else {
                    return nil
                }
                let values = Dictionary(uniqueKeysWithValues: fieldIndices.compactMap { tag, index -> (UInt16, ReflectedFieldValue)? in
                    guard component.values.indices.contains(index) else { return nil }
                    return (tag, component.values[index])
                })
                return try codec.encode(RuntimeTaggedComponentPayload(values: values))
            },
            apply: { data, world, entity, codec in
                let payload = try codec.decode(RuntimeTaggedComponentPayload.self, from: data)
                var component = world.getRuntimeComponent(descriptor.componentID, from: entity) ?? descriptor.makeDefault()
                for (tag, value) in payload.values {
                    guard
                        let index = fieldIndices[tag],
                        component.values.indices.contains(index),
                        descriptor.fields[index].accepts(value)
                    else {
                        continue
                    }
                    component.values[index] = value
                }
                world.insertRuntimeComponent(component, for: entity)
            },
            remove: { world, entity in
                world.remove(descriptor.componentID, from: entity)
            },
            interpolate: { previous, current, alpha, codec in
                let lhs = try codec.decode(RuntimeTaggedComponentPayload.self, from: previous)
                let rhs = try codec.decode(RuntimeTaggedComponentPayload.self, from: current)
                var values = rhs.values
                for field in schema.fields where field.interpolation == .linear {
                    guard let previousValue = lhs.values[field.tag], let currentValue = rhs.values[field.tag] else {
                        continue
                    }
                    switch (previousValue, currentValue) {
                    case let (.double(lhs), .double(rhs)):
                        values[field.tag] = .double(lhs + (rhs - lhs) * Double(alpha))
                    case let (.int(lhs), .int(rhs)):
                        values[field.tag] = .int(Int((Double(lhs) + (Double(rhs - lhs) * Double(alpha))).rounded()))
                    default:
                        continue
                    }
                }
                return try codec.encode(RuntimeTaggedComponentPayload(values: values))
            }
        )
        replicatedComponentsByTypeID[schema.typeID] = replicated
        replicatedTypeIDByComponentID[descriptor.componentID] = schema.typeID
    }

    mutating func registerBuiltInComponents() {
        register(
            NetworkOwner.self,
            id: "ada.network-owner",
            version: 1,
            options: ReplicatedComponentOptions()
        )
        register(
            Transform.self,
            id: "ada.transform",
            version: 1,
            options: ReplicatedComponentOptions { previous, current, alpha in
                Transform(
                    rotation: Quat(
                        x: lerp(previous.rotation.x, current.rotation.x, alpha),
                        y: lerp(previous.rotation.y, current.rotation.y, alpha),
                        z: lerp(previous.rotation.z, current.rotation.z, alpha),
                        w: lerp(previous.rotation.w, current.rotation.w, alpha)
                    ).normalized,
                    scale: lerp(previous.scale, current.scale, alpha),
                    position: lerp(previous.position, current.position, alpha)
                )
            }
        )
    }
}

private struct RuntimeTaggedComponentPayload: Codable, Sendable {
    let values: [UInt16: ReflectedFieldValue]

    init(values: [UInt16: ReflectedFieldValue]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([String: ReflectedFieldValue].self)
        self.values = try Dictionary(uniqueKeysWithValues: values.map { key, value in
            guard let tag = UInt16(key), tag > 0 else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid network field tag")
            }
            return (tag, value)
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: values.map { (String($0.key), $0.value) }))
    }
}

extension AppWorlds {
    /// Registers replication for a component whose layout is defined by a portable runtime schema.
    @discardableResult
    public func registerReplicatedRuntimeComponent(
        _ descriptor: RuntimeComponentDescriptor,
        schema: NetworkTypeDescriptor,
        fieldIndices: [UInt16: Int]
    ) -> Self {
        guard getResource(MultiplayerRegistry.self) != nil else {
            preconditionFailure("Add MultiplayerPlugin before registering network components")
        }
        main.registerRequiredComponent(
            ReplicatedEntity.self,
            forRuntimeComponent: descriptor.componentID,
            constructor: { ReplicatedEntity() }
        )
        getRefResource(MultiplayerRegistry.self).wrappedValue.registerRuntimeComponent(
            descriptor,
            schema: schema,
            fieldIndices: fieldIndices
        )
        return self
    }
}
