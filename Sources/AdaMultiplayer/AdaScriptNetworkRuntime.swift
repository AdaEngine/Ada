import AdaApp
import AdaECS
import AdaUtils
import Foundation

/// One typed command received from a connected peer and detached from transport storage.
public struct AdaScriptRemoteCommandPayload: Equatable, Sendable {
    public let source: String
    public let values: [String: ReflectedFieldValue]

    public init(source: String, values: [String: ReflectedFieldValue]) {
        self.source = source
        self.values = values
    }
}

/// World-scoped storage used by the typed AdaScript multiplayer bridge.
public struct AdaScriptNetworkRuntime: Resource {
    struct Registration: Sendable {
        let fieldNames: [UInt16: String]
        let orderedTags: [UInt16]
        let schema: NetworkTypeDescriptor
    }

    struct OutgoingCommand: Sendable {
        let typeID: String
        let values: [UInt16: ReflectedFieldValue]
    }

    private var commandsByName: [String: String] = [:]
    private var outgoingCommands: [OutgoingCommand] = []
    private var receivedCommands: [String: [AdaScriptRemoteCommandPayload]] = [:]
    private var registrations: [String: Registration] = [:]

    public init() {}

    /// Returns commands received during the latest network-receive stage.
    public func commands(named name: String) -> [AdaScriptRemoteCommandPayload] {
        guard let typeID = commandsByName[name] else {
            return []
        }
        return receivedCommands[typeID] ?? []
    }

    /// Queues a typed command for the network-send stage.
    public mutating func send(commandNamed name: String, values: [ReflectedFieldValue]) -> Bool {
        guard
            let typeID = commandsByName[name],
            let registration = registrations[typeID],
            registration.orderedTags.count == values.count
        else {
            return false
        }
        let taggedValues = Dictionary(
            uniqueKeysWithValues: zip(registration.orderedTags, values).map { ($0, $1) }
        )
        let command = OutgoingCommand(typeID: typeID, values: taggedValues)
        if registration.schema.delivery == .unreliableSequenced,
            let existing = outgoingCommands.lastIndex(where: { $0.typeID == typeID }) {
            outgoingCommands[existing] = command
        } else {
            guard outgoingCommands.count < 256 else {
                return false
            }
            outgoingCommands.append(command)
        }
        return true
    }

    mutating func register(
        name: String,
        schema: NetworkTypeDescriptor,
        fieldNames: [UInt16: String],
        orderedTags: [UInt16]
    ) {
        commandsByName[name] = schema.typeID
        registrations[schema.typeID] = Registration(
            fieldNames: fieldNames,
            orderedTags: orderedTags,
            schema: schema
        )
    }

    mutating func clearReceived(typeID: String) {
        receivedCommands[typeID] = []
    }

    mutating func append(
        typeID: String,
        source: PeerID,
        taggedValues: [UInt16: ReflectedFieldValue]
    ) throws {
        guard let registration = registrations[typeID] else {
            throw MultiplayerError.unknownMessage(typeID)
        }
        var namedValues: [String: ReflectedFieldValue] = [:]
        for (tag, value) in taggedValues {
            guard let name = registration.fieldNames[tag] else {
                continue
            }
            namedValues[name] = value
        }
        receivedCommands[typeID, default: []].append(
            AdaScriptRemoteCommandPayload(
                source: source.rawValue.uuidString,
                values: namedValues
            )
        )
    }

    mutating func drainOutgoing() -> [(Registration, OutgoingCommand)] {
        let commands = outgoingCommands.compactMap { command in
            registrations[command.typeID].map { ($0, command) }
        }
        outgoingCommands.removeAll(keepingCapacity: true)
        return commands
    }
}

extension AppWorlds {
    /// Registers a portable AdaScript command schema in the ordinary RPC registry.
    @discardableResult
    public func registerAdaScriptNetworkCommand(
        name: String,
        schema: NetworkTypeDescriptor,
        fieldNames: [UInt16: String],
        orderedTags: [UInt16]
    ) -> Self {
        guard schema.kind == .command, let direction = schema.direction else {
            preconditionFailure("AdaScript command schema is invalid for \(schema.typeID)")
        }
        let schemaTags = Set(schema.fields.map(\.tag))
        precondition(Set(fieldNames.keys) == schemaTags, "AdaScript command field names must match its schema")
        precondition(Set(orderedTags) == schemaTags, "AdaScript command field order must match its schema")
        guard getResource(MultiplayerRegistry.self) != nil else {
            preconditionFailure("Add MultiplayerPlugin before registering AdaScript network commands")
        }
        if getResource(AdaScriptNetworkRuntime.self) == nil {
            insertResource(AdaScriptNetworkRuntime())
            addSystem(AdaScriptNetworkSendSystem.self, on: .networkSend)
        }
        getRefResource(AdaScriptNetworkRuntime.self).wrappedValue.register(
            name: name,
            schema: schema,
            fieldNames: fieldNames,
            orderedTags: orderedTags
        )

        var registry = getRefResource(MultiplayerRegistry.self).wrappedValue
        precondition(registry.rpcByTypeID[schema.typeID] == nil, "Network message identifier \(schema.typeID) is already registered")
        registry.rpcByTypeID[schema.typeID] = RPCDescriptor(
            typeID: schema.typeID,
            version: schema.version,
            kind: .command,
            direction: direction,
            maximumPayloadSize: schema.maximumPayloadSize,
            schema: schema,
            clear: { world in
                world.getRefResource(AdaScriptNetworkRuntime.self).wrappedValue.clearReceived(typeID: schema.typeID)
            },
            deliver: { source, _, payload, world, _, codec in
                let decoded = try codec.decode(AdaScriptTaggedPayload.self, from: payload)
                try world.getRefResource(AdaScriptNetworkRuntime.self).wrappedValue.append(
                    typeID: schema.typeID,
                    source: source,
                    taggedValues: decoded.values
                )
            }
        )
        getRefResource(MultiplayerRegistry.self).wrappedValue = registry
        return self
    }
}

@PlainSystem
struct AdaScriptNetworkSendSystem {
    @Res<MultiplayerSession>
    private var session

    @ResMut<AdaScriptNetworkRuntime>
    private var runtime

    init(world _: World) {}

    func update(context _: UpdateContext) async {
        guard await session.currentState() == .connected else {
            return
        }
        let commands = runtime.drainOutgoing()
        for (registration, command) in commands {
            do {
                let payload = try JSONNetworkCodec().encode(AdaScriptTaggedPayload(values: command.values))
                try await session.sendCommand(
                    typeID: registration.schema.typeID,
                    version: registration.schema.version,
                    payload: payload
                )
            } catch {
                RuntimeLogStore.shared.append(
                    level: "error",
                    label: "AdaScript.Multiplayer",
                    message: "Typed command send failed: \(error)"
                )
            }
        }
    }
}

private struct AdaScriptTaggedPayload: Codable, Sendable {
    let values: [UInt16: ReflectedFieldValue]

    init(values: [UInt16: ReflectedFieldValue]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode([String: AdaScriptCodableFieldValue].self)
        var values: [UInt16: ReflectedFieldValue] = [:]
        for (key, value) in decoded {
            guard let tag = UInt16(key), tag > 0 else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid network field tag")
            }
            values[tag] = value.value
        }
        self.values = values
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(
            Dictionary(uniqueKeysWithValues: values.map { (String($0.key), AdaScriptCodableFieldValue($0.value)) })
        )
    }
}

private struct AdaScriptCodableFieldValue: Codable, Sendable {
    let value: ReflectedFieldValue

    init(_ value: ReflectedFieldValue) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = .null
        } else if let decoded = try? container.decode(Bool.self) {
            value = .bool(decoded)
        } else if let decoded = try? container.decode(Int.self) {
            value = .int(decoded)
        } else if let decoded = try? container.decode(Double.self) {
            value = .double(decoded)
        } else if let decoded = try? container.decode(String.self) {
            value = .string(decoded)
        } else if let decoded = try? container.decode([Self].self) {
            value = .array(decoded.map(\.value))
        } else if let decoded = try? container.decode([String: Self].self) {
            value = .object(decoded.mapValues(\.value))
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported network field value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(values): try container.encode(values.map(Self.init))
        case let .object(values): try container.encode(values.mapValues(Self.init))
        }
    }
}
