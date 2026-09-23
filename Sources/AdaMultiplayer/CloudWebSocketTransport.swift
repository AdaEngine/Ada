import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Ticket returned by AdaEngine Cloud's create/join endpoints.
public struct CloudRelayCredentials: Sendable {
    public var url: URL
    public var connectionTicket: String

    public init(url: URL, connectionTicket: String) {
        self.url = url
        self.connectionTicket = connectionTicket
    }
}

struct CloudRelayHello: Codable, Sendable {
    var kind = "hello"
    var ticket: String
    var sessionID: UUID
    var peerID: UUID
    var role: NetworkRole
}

struct CloudRelayControl: Codable, Sendable {
    var kind: String
    var peerID: UUID?
    var message: String?
}

struct CloudRelayPacket: Codable, Sendable {
    var source: UUID?
    var target: String
    var peerID: UUID?
    var payload: Data
}

/// Reliable ordered transport backed by the AdaEngine Cloud WebSocket relay.
///
/// The connection ticket is sent as the first WebSocket message, never as part
/// of the URL. The relay reads only the outer routing envelope; `payload` is an
/// opaque AdaMultiplayer frame.
#if !os(WASI)
public actor CloudWebSocketTransport: MultiplayerTransport {
    public nonisolated let capabilities: MultiplayerTransportCapabilities = [.reliableOrdered]

    private let credentials: CloudRelayCredentials
    private let stream: AsyncStream<MultiplayerTransportEvent>
    private let continuation: AsyncStream<MultiplayerTransportEvent>.Continuation
    private var configuration: MultiplayerTransportConfiguration?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    public init(credentials: CloudRelayCredentials) {
        self.credentials = credentials
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
        guard credentials.url.scheme == "wss" || credentials.url.scheme == "ws" else {
            throw MultiplayerError.invalidPayload
        }

        let socket = URLSession.shared.webSocketTask(with: credentials.url)
        self.socket = socket
        self.configuration = configuration
        socket.resume()

        let hello = CloudRelayHello(
            ticket: credentials.connectionTicket,
            sessionID: configuration.sessionID.rawValue,
            peerID: configuration.localPeerID.rawValue,
            role: configuration.role
        )
        try await socket.send(.string(String(decoding: JSONEncoder().encode(hello), as: UTF8.self)))
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket)
        }
    }

    public func send(_ payload: Data, to target: NetworkTarget) async throws {
        guard let socket else {
            throw MultiplayerError.notConnected
        }
        let route: (String, UUID?) = switch target {
        case .host: ("host", nil)
        case let .peer(peer): ("peer", peer.rawValue)
        case .allPeers: ("allPeers", nil)
        case let .allPeersExcept(peer): ("allPeersExcept", peer.rawValue)
        }
        let packet = CloudRelayPacket(
            source: nil,
            target: route.0,
            peerID: route.1,
            payload: payload
        )
        try await socket.send(.data(JSONEncoder().encode(packet)))
    }

    public func stop() async {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        configuration = nil
    }

    private func receiveLoop(socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                switch message {
                case let .string(text):
                    try receiveControl(Data(text.utf8))
                case let .data(data):
                    let packet = try JSONDecoder().decode(CloudRelayPacket.self, from: data)
                    guard let source = packet.source else {
                        throw MultiplayerError.invalidPayload
                    }
                    continuation.yield(
                        .received(source: PeerID(rawValue: source), payload: packet.payload)
                    )
                @unknown default:
                    throw MultiplayerError.invalidPayload
                }
            }
        } catch {
            guard !Task.isCancelled else {
                return
            }
            continuation.yield(.failed(String(describing: error)))
        }
    }

    private func receiveControl(_ data: Data) throws {
        let control = try JSONDecoder().decode(CloudRelayControl.self, from: data)
        switch control.kind {
        case "ready", "connected":
            guard let peer = control.peerID else {
                return
            }
            continuation.yield(.connected(PeerID(rawValue: peer)))
        case "disconnected":
            guard let peer = control.peerID else {
                return
            }
            continuation.yield(.disconnected(PeerID(rawValue: peer)))
        case "ended", "error":
            continuation.yield(.failed(control.message ?? "Cloud relay ended the session"))
        default:
            throw MultiplayerError.invalidPayload
        }
    }
}
#endif
