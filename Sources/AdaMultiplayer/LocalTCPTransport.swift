#if canImport(Network)
import AdaUtils
import Foundation
@unsafe import Network

public actor LocalTCPTransport: MultiplayerTransport {
    nonisolated public let capabilities: MultiplayerTransportCapabilities = [.reliableOrdered]

    private struct Hello: Codable, Sendable {
        var sessionID: SessionID
        var peerID: PeerID
        var role: NetworkRole
    }

    private enum EnvelopeKind: UInt8 {
        case hello = 1
        case payload = 2
    }

    private enum TransportError: Error, LocalizedError {
        case invalidPort
        case invalidEnvelope
        case incompatibleSession
        case unavailableTarget

        var errorDescription: String? {
            switch self {
            case .invalidPort: "The local multiplayer port is invalid."
            case .invalidEnvelope: "The local multiplayer frame is malformed."
            case .incompatibleSession: "The local peer belongs to another session."
            case .unavailableTarget: "The requested local multiplayer target is unavailable."
            }
        }
    }

    private let host: String
    private let portNumber: UInt16
    private let log: @Sendable (String) -> Void
    private let stream: AsyncStream<MultiplayerTransportEvent>
    private let continuation: AsyncStream<MultiplayerTransportEvent>.Continuation

    private var configuration: MultiplayerTransportConfiguration?
    private var listener: NWListener?
    private var hostConnection: NWConnection?
    private var hostPeerID: PeerID?
    private var connections: [PeerID: NWConnection] = [:]
    private var peersByConnection: [ObjectIdentifier: PeerID] = [:]
    private var pendingConnections: [ObjectIdentifier: NWConnection] = [:]

    public init(
        host: String,
        port: UInt16,
        log: @escaping @Sendable (String) -> Void = { message in
            RuntimeLogStore.shared.append(level: "info", label: "AdaMultiplayer.LocalTCP", message: message)
        }
    ) {
        self.host = host
        self.portNumber = port
        self.log = log
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
        guard let port = NWEndpoint.Port(rawValue: portNumber) else {
            throw TransportError.invalidPort
        }
        self.configuration = configuration

        switch configuration.role {
        case .host:
            let listener = try NWListener(using: .tcp, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
            log("listening on 0.0.0.0:\(portNumber)")
        case .peer:
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            hostConnection = connection
            configure(connection)
            connection.start(queue: .global(qos: .userInitiated))
            log("connecting to \(host):\(portNumber)")
        }
    }

    public func send(_ payload: Data, to target: NetworkTarget) async throws {
        guard let configuration else {
            throw MultiplayerError.notConnected
        }
        let envelope = Data([EnvelopeKind.payload.rawValue]) + payload
        switch (configuration.role, target) {
        case (.peer, .host):
            guard let hostConnection else {
                throw TransportError.unavailableTarget
            }
            try await sendEnvelope(envelope, through: hostConnection)
        case let (.host, .peer(peer)):
            guard let connection = connections[peer] else {
                throw TransportError.unavailableTarget
            }
            try await sendEnvelope(envelope, through: connection)
        case (.host, .allPeers):
            for connection in connections.values {
                try await sendEnvelope(envelope, through: connection)
            }
        case let (.host, .allPeersExcept(excluded)):
            for (peer, connection) in connections where peer != excluded {
                try await sendEnvelope(envelope, through: connection)
            }
        default:
            throw MultiplayerError.invalidDirection
        }
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        hostConnection?.cancel()
        hostConnection = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        peersByConnection.removeAll()
        pendingConnections.removeAll()
        configuration = nil
        log("transport stopped")
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .failed(let error):
            continuation.yield(.failed(error.localizedDescription))
            log("listener failed: \(error)")
        case .ready:
            log("listener ready")
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        pendingConnections[ObjectIdentifier(connection)] = connection
        configure(connection)
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func configure(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else {
                return
            }
            Task { await self?.connectionChanged(connection, state: state) }
        }
        receiveHeader(from: connection)
    }

    private func connectionChanged(_ connection: NWConnection, state: NWConnection.State) async {
        switch state {
        case .ready:
            guard let configuration, configuration.role == .peer else {
                return
            }
            do {
                try await sendHello(configuration, through: connection)
            } catch {
                fail(connection, error: error)
            }
        case .failed(let error):
            fail(connection, error: error)
        case .waiting(let error):
            log("connection waiting: \(error)")
        case .cancelled:
            disconnect(connection)
        default:
            break
        }
    }

    private func receiveHeader(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }
            Task {
                if let error {
                    await self.fail(connection, error: error)
                    return
                }
                guard let data, data.count == 4 else {
                    if isComplete {
                        await self.disconnect(connection)
                    } else {
                        await self.fail(connection, error: TransportError.invalidEnvelope)
                    }
                    return
                }
                let size = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard size > 0, size <= 1_048_576 else {
                    await self.fail(connection, error: TransportError.invalidEnvelope)
                    return
                }
                await self.receiveBody(Int(size), from: connection)
            }
        }
    }

    private func receiveBody(_ size: Int, from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }
            Task {
                if let error {
                    await self.fail(connection, error: error)
                    return
                }
                guard let data, data.count == size else {
                    if isComplete {
                        await self.disconnect(connection)
                    } else {
                        await self.fail(connection, error: TransportError.invalidEnvelope)
                    }
                    return
                }
                do {
                    try await self.receiveEnvelope(data, from: connection)
                    await self.receiveHeader(from: connection)
                } catch {
                    await self.fail(connection, error: error)
                }
            }
        }
    }

    private func receiveEnvelope(_ envelope: Data, from connection: NWConnection) async throws {
        guard let kindByte = envelope.first, let kind = EnvelopeKind(rawValue: kindByte) else {
            throw TransportError.invalidEnvelope
        }
        let payload = envelope.dropFirst()
        switch kind {
        case .hello:
            let hello = try JSONDecoder().decode(Hello.self, from: payload)
            try await receiveHello(hello, from: connection)
        case .payload:
            let source: PeerID?
            if configuration?.role == .host {
                source = peersByConnection[ObjectIdentifier(connection)]
            } else {
                source = hostPeerID
            }
            guard let source else {
                throw TransportError.invalidEnvelope
            }
            continuation.yield(.received(source: source, payload: Data(payload)))
        }
    }

    private func receiveHello(_ hello: Hello, from connection: NWConnection) async throws {
        guard let configuration,
              hello.sessionID == configuration.sessionID,
              hello.role != configuration.role else {
            throw TransportError.incompatibleSession
        }

        switch configuration.role {
        case .host:
            guard hello.role == .peer else {
                throw TransportError.incompatibleSession
            }
            let identifier = ObjectIdentifier(connection)
            pendingConnections[identifier] = nil
            connections[hello.peerID]?.cancel()
            connections[hello.peerID] = connection
            peersByConnection[identifier] = hello.peerID
            try await sendHello(configuration, through: connection)
            continuation.yield(.connected(hello.peerID))
            log("connected peer \(hello.peerID.rawValue.uuidString)")
        case .peer:
            guard hello.role == .host else {
                throw TransportError.incompatibleSession
            }
            hostPeerID = hello.peerID
            continuation.yield(.connected(hello.peerID))
            log("connected host \(hello.peerID.rawValue.uuidString)")
        }
    }

    private func sendHello(
        _ configuration: MultiplayerTransportConfiguration,
        through connection: NWConnection
    ) async throws {
        let hello = Hello(
            sessionID: configuration.sessionID,
            peerID: configuration.localPeerID,
            role: configuration.role
        )
        let envelope = Data([EnvelopeKind.hello.rawValue]) + (try JSONEncoder().encode(hello))
        try await sendEnvelope(envelope, through: connection)
    }

    private func sendEnvelope(_ envelope: Data, through connection: NWConnection) async throws {
        let size = UInt32(envelope.count)
        var frame = Data([
            UInt8(size >> 24),
            UInt8(truncatingIfNeeded: size >> 16),
            UInt8(truncatingIfNeeded: size >> 8),
            UInt8(truncatingIfNeeded: size),
        ])
        frame.append(envelope)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func fail(_ connection: NWConnection, error: any Error) {
        log("connection failed: \(error)")
        continuation.yield(.failed(error.localizedDescription))
        connection.cancel()
        disconnect(connection)
    }

    private func disconnect(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        pendingConnections[identifier] = nil
        if let peer = peersByConnection.removeValue(forKey: identifier) {
            connections[peer] = nil
            continuation.yield(.disconnected(peer))
            log("disconnected peer \(peer.rawValue.uuidString)")
        } else if connection === hostConnection, let hostPeerID {
            self.hostPeerID = nil
            hostConnection = nil
            continuation.yield(.disconnected(hostPeerID))
            log("disconnected host \(hostPeerID.rawValue.uuidString)")
        }
    }
}
#else
import Foundation

/// Reliable development transport for direct local-network sessions.
///
/// The reference implementation uses Network.framework and is therefore only
/// available on Apple platforms. Other platforms can provide their own
/// ``MultiplayerTransport`` implementation without changing AdaScript code.
public actor LocalTCPTransport: MultiplayerTransport {
    nonisolated public let capabilities: MultiplayerTransportCapabilities = [.reliableOrdered]

    public init(
        host _: String,
        port _: UInt16,
        log _: @escaping @Sendable (String) -> Void = { _ in }
    ) {}

    public func eventStream() -> AsyncStream<MultiplayerTransportEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func start(configuration _: MultiplayerTransportConfiguration) async throws {
        throw MultiplayerError.unsupportedPlatform
    }

    public func send(_: Data, to _: NetworkTarget) async throws {
        throw MultiplayerError.unsupportedPlatform
    }

    public func stop() async {}
}
#endif
