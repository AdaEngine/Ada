import AdaApp
import AdaECS
import Foundation

/// Common wire identity for typed RPC messages.
public protocol NetworkMessage: Codable, Sendable {
    static var networkIdentifier: String { get }
    static var networkVersion: UInt16 { get }
}

extension NetworkMessage {
    public static var networkVersion: UInt16 { 1 }
}

/// One-way message sent by a peer to the authoritative host.
public protocol NetworkCommand: NetworkMessage {}

/// One-way message emitted by the host for one or more peers.
public protocol NetworkEvent: NetworkMessage {}

/// Correlated request whose response is encoded by the same RPC registry.
public protocol NetworkRequest: NetworkMessage {
    associatedtype Response: Codable & Sendable
}

/// Allowed direction for a registered RPC message.
public enum RPCDirection: String, Codable, Hashable, Sendable {
    case peerToHost
    case hostToPeer
    case bidirectional
}

enum RPCMessageKind: String, Codable, Sendable {
    case command
    case event
    case request
}

struct RPCDescriptor: Sendable {
    var typeID: String
    var version: UInt16
    var kind: RPCMessageKind
    var direction: RPCDirection
    var maximumPayloadSize: Int
    var schema: NetworkTypeDescriptor?
    var clear: @Sendable (World) -> Void
    var deliver: @Sendable (
        _ source: PeerID,
        _ correlationID: UUID?,
        _ payload: Data,
        _ world: World,
        _ session: MultiplayerSession,
        _ codec: any NetworkCodec
    ) throws -> Void
}

/// A typed command together with its authenticated transport source.
public struct RemoteCommand<T: NetworkCommand>: Sendable {
    public let source: PeerID
    public let value: T
}

private struct RemoteCommandStorage<T: NetworkCommand>: Resource {
    var values: [RemoteCommand<T>] = []
}

/// System parameter containing commands received during `networkReceive`.
@propertyWrapper
public final class RemoteCommands<T: NetworkCommand>: @unchecked Sendable {
    private var storage: Ref<RemoteCommandStorage<T>>?

    public var wrappedValue: [RemoteCommand<T>] {
        storage?.wrappedValue.values ?? []
    }

    public init() {}
}

extension RemoteCommands: SystemParameter {
    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        access.addResourceRead(RemoteCommandStorage<T>.self)
        return access
    }

    public convenience init(from _: World) {
        self.init()
    }

    public func update(from world: World) {
        storage = world.getOrInitRefResource(RemoteCommandStorage<T>.self) {
            RemoteCommandStorage()
        }
    }
}

/// A typed event together with the host that emitted it.
public struct RemoteEvent<T: NetworkEvent>: Sendable {
    public let source: PeerID
    public let value: T
}

private struct RemoteEventStorage<T: NetworkEvent>: Resource {
    var values: [RemoteEvent<T>] = []
}

/// System parameter containing host events received during `networkReceive`.
@propertyWrapper
public final class RemoteEvents<T: NetworkEvent>: @unchecked Sendable {
    private var storage: Ref<RemoteEventStorage<T>>?

    public var wrappedValue: [RemoteEvent<T>] {
        storage?.wrappedValue.values ?? []
    }

    public init() {}
}

extension RemoteEvents: SystemParameter {
    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        access.addResourceRead(RemoteEventStorage<T>.self)
        return access
    }

    public convenience init(from _: World) {
        self.init()
    }

    public func update(from world: World) {
        storage = world.getOrInitRefResource(RemoteEventStorage<T>.self) {
            RemoteEventStorage()
        }
    }
}

/// Sends the response for one received request exactly through its source path.
public struct RPCResponder<Response: Codable & Sendable>: Sendable {
    let session: MultiplayerSession
    let correlationID: UUID
    let typeID: String
    let version: UInt16
    let peer: PeerID

    public func respond(_ response: Response) async throws {
        try await session.sendResponse(
            response,
            correlationID: correlationID,
            typeID: typeID,
            version: version,
            to: peer
        )
    }
}

/// A decoded request and its correlated responder.
public struct RemoteRequest<T: NetworkRequest>: Sendable {
    public let source: PeerID
    public let value: T
    public let responder: RPCResponder<T.Response>
}

private struct RemoteRequestStorage<T: NetworkRequest>: Resource {
    var values: [RemoteRequest<T>] = []
}

/// System parameter containing requests received during `networkReceive`.
@propertyWrapper
public final class RemoteRequests<T: NetworkRequest>: @unchecked Sendable {
    private var storage: Ref<RemoteRequestStorage<T>>?

    public var wrappedValue: [RemoteRequest<T>] {
        storage?.wrappedValue.values ?? []
    }

    public init() {}
}

extension RemoteRequests: SystemParameter {
    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        access.addResourceRead(RemoteRequestStorage<T>.self)
        return access
    }

    public convenience init(from _: World) {
        self.init()
    }

    public func update(from world: World) {
        storage = world.getOrInitRefResource(RemoteRequestStorage<T>.self) {
            RemoteRequestStorage()
        }
    }
}

extension AppWorlds {
    /// Registers a peer-to-host command type.
    @discardableResult
    public func registerNetworkCommand<T: NetworkCommand>(
        _ type: T.Type,
        direction: RPCDirection = .peerToHost,
        maximumPayloadSize: Int = 64 * 1_024
    ) -> Self {
        registerRPC(
            type,
            kind: .command,
            direction: direction,
            maximumPayloadSize: maximumPayloadSize,
            clear: { world in
                world.getOrInitRefResource(RemoteCommandStorage<T>.self) {
                    RemoteCommandStorage()
                }.wrappedValue.values.removeAll(keepingCapacity: true)
            },
            deliver: { source, _, payload, world, _, codec in
                let value = try codec.decode(T.self, from: payload)
                world.getOrInitRefResource(RemoteCommandStorage<T>.self) {
                    RemoteCommandStorage()
                }.wrappedValue.values.append(RemoteCommand(source: source, value: value))
            }
        )
    }

    /// Registers a command using metadata synthesized by ``NetworkCommand(id:version:direction:delivery:channel:maximumPayloadSize:)``.
    @discardableResult
    public func registerNetworkCommand<T: NetworkCommand & NetworkDescribedMessage>(
        _ type: T.Type
    ) -> Self {
        let schema = T.networkDescriptor
        guard schema.kind == .command, let direction = schema.direction else {
            preconditionFailure("Generated command schema is invalid for \(schema.typeID)")
        }
        return registerNetworkCommand(
            type,
            direction: direction,
            maximumPayloadSize: schema.maximumPayloadSize
        )
    }

    /// Registers a host-to-peer event type.
    @discardableResult
    public func registerNetworkEvent<T: NetworkEvent>(
        _ type: T.Type,
        direction: RPCDirection = .hostToPeer,
        maximumPayloadSize: Int = 64 * 1_024
    ) -> Self {
        registerRPC(
            type,
            kind: .event,
            direction: direction,
            maximumPayloadSize: maximumPayloadSize,
            clear: { world in
                world.getOrInitRefResource(RemoteEventStorage<T>.self) {
                    RemoteEventStorage()
                }.wrappedValue.values.removeAll(keepingCapacity: true)
            },
            deliver: { source, _, payload, world, _, codec in
                let value = try codec.decode(T.self, from: payload)
                world.getOrInitRefResource(RemoteEventStorage<T>.self) {
                    RemoteEventStorage()
                }.wrappedValue.values.append(RemoteEvent(source: source, value: value))
            }
        )
    }

    /// Registers a correlated request/response type.
    @discardableResult
    public func registerNetworkRequest<T: NetworkRequest>(
        _ type: T.Type,
        direction: RPCDirection = .bidirectional,
        maximumPayloadSize: Int = 64 * 1_024
    ) -> Self {
        registerRPC(
            type,
            kind: .request,
            direction: direction,
            maximumPayloadSize: maximumPayloadSize,
            clear: { world in
                world.getOrInitRefResource(RemoteRequestStorage<T>.self) {
                    RemoteRequestStorage()
                }.wrappedValue.values.removeAll(keepingCapacity: true)
            },
            deliver: { source, correlationID, payload, world, session, codec in
                guard let correlationID else {
                    throw MultiplayerError.invalidPayload
                }
                let value = try codec.decode(T.self, from: payload)
                let responder = RPCResponder<T.Response>(
                    session: session,
                    correlationID: correlationID,
                    typeID: T.networkIdentifier,
                    version: T.networkVersion,
                    peer: source
                )
                world.getOrInitRefResource(RemoteRequestStorage<T>.self) {
                    RemoteRequestStorage()
                }.wrappedValue.values.append(
                    RemoteRequest(source: source, value: value, responder: responder)
                )
            }
        )
    }

    @discardableResult
    private func registerRPC<T: NetworkMessage>(
        _ type: T.Type,
        kind: RPCMessageKind,
        direction: RPCDirection,
        maximumPayloadSize: Int,
        clear: @escaping @Sendable (World) -> Void,
        deliver: @escaping @Sendable (
            PeerID,
            UUID?,
            Data,
            World,
            MultiplayerSession,
            any NetworkCodec
        ) throws -> Void
    ) -> Self {
        guard getResource(MultiplayerRegistry.self) != nil else {
            preconditionFailure("Add MultiplayerPlugin before registering network messages")
        }
        var registry = getRefResource(MultiplayerRegistry.self).wrappedValue
        precondition(!T.networkIdentifier.isEmpty, "Network message identifier must not be empty")
        precondition(registry.rpcByTypeID[T.networkIdentifier] == nil, "Network message identifier \(T.networkIdentifier) is already registered")
        registry.rpcByTypeID[T.networkIdentifier] = RPCDescriptor(
            typeID: T.networkIdentifier,
            version: T.networkVersion,
            kind: kind,
            direction: direction,
            maximumPayloadSize: max(1, maximumPayloadSize),
            schema: (T.self as? any NetworkDescribedMessage.Type)?.networkDescriptor,
            clear: clear,
            deliver: deliver
        )
        getRefResource(MultiplayerRegistry.self).wrappedValue = registry
        return self
    }
}
