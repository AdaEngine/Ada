import Foundation

/// Delivery features exposed by a multiplayer transport.
public struct MultiplayerTransportCapabilities: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let reliableOrdered = Self(rawValue: 1 << 0)
    public static let unreliable = Self(rawValue: 1 << 1)
    public static let localDiscovery = Self(rawValue: 1 << 2)
}

/// Information needed to attach a transport endpoint to a logical session.
public struct MultiplayerTransportConfiguration: Sendable {
    public var role: NetworkRole
    public var sessionID: SessionID
    public var localPeerID: PeerID

    public init(role: NetworkRole, sessionID: SessionID, localPeerID: PeerID) {
        self.role = role
        self.sessionID = sessionID
        self.localPeerID = localPeerID
    }
}

/// Events delivered by an active multiplayer transport.
public enum MultiplayerTransportEvent: Sendable {
    case connected(PeerID)
    case disconnected(PeerID)
    case received(source: PeerID, payload: Data)
    case failed(String)
}

/// Replaceable byte transport used by ``MultiplayerPlugin``.
///
/// Implementations must not retain or mutate an AdaECS `World`. They deliver
/// `Sendable` events which are consumed by the network receive scheduler.
public protocol MultiplayerTransport: Sendable {
    var capabilities: MultiplayerTransportCapabilities { get }

    func eventStream() async -> AsyncStream<MultiplayerTransportEvent>
    func start(configuration: MultiplayerTransportConfiguration) async throws
    func send(_ payload: Data, to target: NetworkTarget) async throws
    func stop() async
}

/// In-process star router used by tests, previews, and custom server embedding.
public actor InMemoryTransportHub {
    private struct Endpoint: Sendable {
        var role: NetworkRole
        var continuation: AsyncStream<MultiplayerTransportEvent>.Continuation
    }

    private var endpoints: [PeerID: Endpoint] = [:]
    private var host: PeerID?

    public init() {}

    func connect(
        peer: PeerID,
        role: NetworkRole,
        continuation: AsyncStream<MultiplayerTransportEvent>.Continuation
    ) throws {
        if role == .host {
            guard host == nil || host == peer else {
                throw MultiplayerError.invalidDirection
            }
            host = peer
        } else if host == nil {
            throw MultiplayerError.notConnected
        }

        let connectedPeers = Array(endpoints.keys)
        endpoints[peer] = Endpoint(role: role, continuation: continuation)
        for connectedPeer in connectedPeers {
            endpoints[connectedPeer]?.continuation.yield(.connected(peer))
            continuation.yield(.connected(connectedPeer))
        }
    }

    func disconnect(peer: PeerID) {
        guard endpoints.removeValue(forKey: peer) != nil else {
            return
        }
        if host == peer {
            host = nil
        }
        for endpoint in endpoints.values {
            endpoint.continuation.yield(.disconnected(peer))
        }
    }

    func send(_ payload: Data, source: PeerID, target: NetworkTarget) throws {
        guard let sourceEndpoint = endpoints[source] else {
            throw MultiplayerError.notConnected
        }

        let recipients: [PeerID]
        switch target {
        case .host:
            guard sourceEndpoint.role == .peer, let host else {
                throw MultiplayerError.invalidDirection
            }
            recipients = [host]
        case let .peer(peer):
            guard sourceEndpoint.role == .host else {
                throw MultiplayerError.invalidDirection
            }
            recipients = [peer]
        case .allPeers:
            guard sourceEndpoint.role == .host else {
                throw MultiplayerError.invalidDirection
            }
            recipients = endpoints.compactMap { peer, endpoint in
                endpoint.role == .peer ? peer : nil
            }
        case let .allPeersExcept(excluded):
            guard sourceEndpoint.role == .host else {
                throw MultiplayerError.invalidDirection
            }
            recipients = endpoints.compactMap { peer, endpoint in
                endpoint.role == .peer && peer != excluded ? peer : nil
            }
        }

        for recipient in recipients {
            endpoints[recipient]?.continuation.yield(.received(source: source, payload: payload))
        }
    }
}

/// A concrete transport endpoint backed by ``InMemoryTransportHub``.
public actor InMemoryTransport: MultiplayerTransport {
    public nonisolated let capabilities: MultiplayerTransportCapabilities = [.reliableOrdered]

    private let hub: InMemoryTransportHub
    private let stream: AsyncStream<MultiplayerTransportEvent>
    private let continuation: AsyncStream<MultiplayerTransportEvent>.Continuation
    private var configuration: MultiplayerTransportConfiguration?

    public init(hub: InMemoryTransportHub) {
        self.hub = hub
        let pair = AsyncStream<MultiplayerTransportEvent>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    public func eventStream() -> AsyncStream<MultiplayerTransportEvent> {
        stream
    }

    public func start(configuration: MultiplayerTransportConfiguration) async throws {
        guard self.configuration == nil else {
            return
        }
        try await hub.connect(
            peer: configuration.localPeerID,
            role: configuration.role,
            continuation: continuation
        )
        self.configuration = configuration
    }

    public func send(_ payload: Data, to target: NetworkTarget) async throws {
        guard let configuration else {
            throw MultiplayerError.notConnected
        }
        try await hub.send(payload, source: configuration.localPeerID, target: target)
    }

    public func stop() async {
        guard let configuration else {
            return
        }
        await hub.disconnect(peer: configuration.localPeerID)
        self.configuration = nil
    }
}
