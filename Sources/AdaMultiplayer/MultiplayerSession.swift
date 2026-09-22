import AdaECS
import Foundation

/// Actor that owns transport lifetime and asynchronous request continuations.
public actor MultiplayerSession: Resource {
    private struct PendingResponse: Sendable {
        var continuation: AsyncThrowingStream<Data, any Error>.Continuation
        var timeout: Task<Void, Never>
    }

    public let configuration: MultiplayerConfiguration

    private let transport: any MultiplayerTransport
    private var state: MultiplayerSessionState = .idle
    private var connectedPeers: Set<PeerID> = []
    private var incomingEvents: [MultiplayerTransportEvent] = []
    private var eventTask: Task<Void, Never>?
    private var disconnectTasks: [PeerID: Task<Void, Never>] = [:]
    private var pendingResponses: [UUID: PendingResponse] = [:]

    public init(configuration: MultiplayerConfiguration, transport: any MultiplayerTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    public func currentState() -> MultiplayerSessionState {
        state
    }

    public func peers() -> Set<PeerID> {
        connectedPeers
    }

    func ensureStarted() async {
        guard state == .idle else {
            return
        }
        state = .connecting
        let stream = await transport.eventStream()
        eventTask = Task { [weak self] in
            for await event in stream {
                await self?.enqueue(event)
            }
        }
        do {
            try await transport.start(
                configuration: MultiplayerTransportConfiguration(
                    role: configuration.role,
                    sessionID: configuration.sessionID,
                    localPeerID: configuration.localPeerID
                )
            )
            if configuration.role == .host {
                state = .connected
            }
        } catch {
            state = .ended(.transportFailure(String(describing: error)))
            incomingEvents.append(.failed(String(describing: error)))
        }
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        for task in disconnectTasks.values {
            task.cancel()
        }
        disconnectTasks.removeAll()
        for response in pendingResponses.values {
            response.timeout.cancel()
            response.continuation.finish(throwing: MultiplayerError.sessionEnded)
        }
        pendingResponses.removeAll()
        await transport.stop()
        connectedPeers.removeAll()
        state = .ended(.stopped)
    }

    func drainTransportEvents() -> [MultiplayerTransportEvent] {
        let events = incomingEvents
        incomingEvents.removeAll(keepingCapacity: true)
        return events
    }

    func markConnected(_ peer: PeerID) {
        disconnectTasks.removeValue(forKey: peer)?.cancel()
        connectedPeers.insert(peer)
        state = .connected
    }

    func markDisconnected(_ peer: PeerID) {
        connectedPeers.remove(peer)
        if configuration.role == .peer {
            let delay = configuration.disconnectGracePeriod
            disconnectTasks[peer]?.cancel()
            disconnectTasks[peer] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else {
                    return
                }
                await self?.endAfterDisconnect(peer)
            }
        }
    }

    func end(_ reason: MultiplayerSessionEndReason) {
        state = .ended(reason)
    }

    func send(frame: NetworkFrame, to target: NetworkTarget) async throws {
        guard state == .connected || state == .connecting else {
            throw MultiplayerError.notConnected
        }
        try await transport.send(NetworkWireCodec.encode(frame), to: target)
    }

    /// Sends a typed one-way command to the authoritative host.
    public func sendCommand<T: NetworkCommand>(_ command: T) async throws {
        guard configuration.role == .peer else {
            throw MultiplayerError.peerOnly
        }
        let payload = try JSONNetworkCodec().encode(command)
        try await send(
            frame: NetworkFrame(
                kind: .command,
                typeID: T.networkIdentifier,
                typeVersion: T.networkVersion,
                payload: payload
            ),
            to: .host
        )
    }

    /// Sends a typed event from the host to one or more peers.
    public func sendEvent<T: NetworkEvent>(_ event: T, to target: NetworkTarget = .allPeers) async throws {
        guard configuration.role == .host else {
            throw MultiplayerError.hostOnly
        }
        let payload = try JSONNetworkCodec().encode(event)
        try await send(
            frame: NetworkFrame(
                kind: .event,
                typeID: T.networkIdentifier,
                typeVersion: T.networkVersion,
                payload: payload
            ),
            to: target
        )
    }

    /// Sends a typed request and waits for its correlated response.
    public func request<T: NetworkRequest>(
        _ request: T,
        to requestedTarget: NetworkTarget? = nil,
        timeout: TimeInterval = 5
    ) async throws -> T.Response {
        let target: NetworkTarget
        switch (configuration.role, requestedTarget) {
        case (.peer, nil), (.peer, .host?):
            target = .host
        case let (.host, .peer(peer)?):
            target = .peer(peer)
        default:
            throw MultiplayerError.invalidDirection
        }
        let correlationID = UUID()
        let pair = AsyncThrowingStream<Data, any Error>.makeStream()
        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await self?.failResponse(correlationID, error: MultiplayerError.requestTimedOut)
        }
        pendingResponses[correlationID] = PendingResponse(
            continuation: pair.continuation,
            timeout: timeoutTask
        )

        do {
            let payload = try JSONNetworkCodec().encode(request)
            try await send(
                frame: NetworkFrame(
                    kind: .request,
                    typeID: T.networkIdentifier,
                    typeVersion: T.networkVersion,
                    correlationID: correlationID,
                    payload: payload
                ),
                to: target
            )
            for try await data in pair.stream {
                return try JSONNetworkCodec().decode(T.Response.self, from: data)
            }
            throw MultiplayerError.sessionEnded
        } catch {
            failResponse(correlationID, error: error)
            throw error
        }
    }

    func sendResponse<T: Codable & Sendable>(
        _ response: T,
        correlationID: UUID,
        typeID: String,
        version: UInt16,
        to peer: PeerID
    ) async throws {
        try await send(
            frame: NetworkFrame(
                kind: .response,
                typeID: typeID,
                typeVersion: version,
                correlationID: correlationID,
                payload: try JSONNetworkCodec().encode(response)
            ),
            to: configuration.role == .host ? .peer(peer) : .host
        )
    }

    func resolveResponse(_ correlationID: UUID, payload: Data) {
        guard let pending = pendingResponses.removeValue(forKey: correlationID) else {
            return
        }
        pending.timeout.cancel()
        pending.continuation.yield(payload)
        pending.continuation.finish()
    }

    private func enqueue(_ event: MultiplayerTransportEvent) {
        incomingEvents.append(event)
    }

    private func endAfterDisconnect(_ peer: PeerID) {
        disconnectTasks[peer] = nil
        guard !connectedPeers.contains(peer) else {
            return
        }
        state = .ended(.hostDisconnected)
    }

    private func failResponse(_ correlationID: UUID, error: any Error) {
        guard let pending = pendingResponses.removeValue(forKey: correlationID) else {
            return
        }
        pending.timeout.cancel()
        pending.continuation.finish(throwing: error)
    }
}
