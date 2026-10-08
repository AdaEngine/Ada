#if canImport(Network)
    import Foundation
    import Network

    /// Bonjour service discovered by ``AppleLocalDiscovery``.
    public struct AppleLocalService: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let endpoint: NWEndpoint

        init(name: String, endpoint: NWEndpoint) {
            self.id = String(describing: endpoint)
            self.name = name
            self.endpoint = endpoint
        }
    }

    /// Discovers Apple LAN hosts advertising the AdaMultiplayer QUIC service.
    public actor AppleLocalDiscovery {
        public static let serviceType = "_ada-mp._udp"

        private let stream: AsyncStream<[AppleLocalService]>
        private let continuation: AsyncStream<[AppleLocalService]>.Continuation
        private var browser: NWBrowser?

        public init() {
            let pair = AsyncStream<[AppleLocalService]>.makeStream()
            self.stream = pair.stream
            self.continuation = pair.continuation
        }

        public func resultStream() -> AsyncStream<[AppleLocalService]> {
            stream
        }

        public func start() {
            guard browser == nil else { return }
            let browser = NWBrowser(
                for: .bonjour(type: Self.serviceType, domain: nil),
                using: AppleLocalTransport.discoveryParameters()
            )
            self.browser = browser
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let services = results.compactMap { result -> AppleLocalService? in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return AppleLocalService(name: name, endpoint: result.endpoint)
                }.sorted { $0.id < $1.id }
                Task { await self?.publish(services) }
            }
            browser.start(queue: .global(qos: .userInitiated))
        }

        public func stop() {
            browser?.cancel()
            browser = nil
            continuation.yield([])
        }

        private func publish(_ services: [AppleLocalService]) {
            continuation.yield(services)
        }
    }

    /// Host or join mode for ``AppleLocalTransport``.
    public enum AppleLocalTransportMode: Sendable {
        case host(serviceName: String)
        case peer(endpoint: NWEndpoint)
    }

    private actor AppleLocalChannel {
        private static let maximumFrameBytes = 8 * 1_024 * 1_024
        private let connection: NWConnection

        init(_ connection: NWConnection) {
            self.connection = connection
        }

        func start() {
            connection.start(queue: .global(qos: .userInitiated))
        }

        func stop() {
            connection.cancel()
        }

        func send(_ payload: Data) async throws {
            guard payload.count <= Self.maximumFrameBytes else {
                throw MultiplayerError.invalidPayload
            }
            let count = UInt32(payload.count)
            var frame = Data([
                UInt8(count >> 24),
                UInt8(truncatingIfNeeded: count >> 16),
                UInt8(truncatingIfNeeded: count >> 8),
                UInt8(truncatingIfNeeded: count),
            ])
            frame.append(payload)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        }

        func receive() async throws -> Data {
            let header = try await read(count: 4)
            let count = header.reduce(0) { ($0 << 8) | Int($1) }
            guard count > 0, count <= Self.maximumFrameBytes else {
                throw MultiplayerError.invalidPayload
            }
            return try await read(count: count)
        }

        private func read(count: Int) async throws -> Data {
            var result = Data()
            while result.count < count {
                let remaining = count - result.count
                let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(
                        minimumIncompleteLength: 1,
                        maximumLength: min(remaining, 64 * 1_024)
                    ) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else {
                            continuation.resume(
                                throwing: complete
                                    ? MultiplayerError.sessionEnded
                                    : MultiplayerError.invalidPayload
                            )
                        }
                    }
                }
                result.append(chunk)
            }
            return result
        }
    }

    /// Direct Apple LAN transport using a reliable QUIC stream and Bonjour.
    public actor AppleLocalTransport: MultiplayerTransport {
        public nonisolated let capabilities: MultiplayerTransportCapabilities = [
            .reliableOrdered,
            .localDiscovery,
        ]

        private let mode: AppleLocalTransportMode
        private let configureQUIC: @Sendable (NWProtocolQUIC.Options) -> Void
        private let stream: AsyncStream<MultiplayerTransportEvent>
        private let continuation: AsyncStream<MultiplayerTransportEvent>.Continuation
        private var configuration: MultiplayerTransportConfiguration?
        private var listener: NWListener?
        private var channels: [PeerID: AppleLocalChannel] = [:]
        private var receiveTasks: [PeerID: Task<Void, Never>] = [:]

        /// Creates a local transport with application-owned TLS identity and
        /// trust configuration.
        ///
        /// QUIC always uses TLS. `configureQUIC` must install the local
        /// identity for a host and pin or otherwise validate the remote
        /// identity for a peer.
        public init(
            mode: AppleLocalTransportMode,
            configureQUIC: @escaping @Sendable (NWProtocolQUIC.Options) -> Void
        ) {
            self.mode = mode
            self.configureQUIC = configureQUIC
            let pair = AsyncStream<MultiplayerTransportEvent>.makeStream()
            self.stream = pair.stream
            self.continuation = pair.continuation
        }

        public func eventStream() -> AsyncStream<MultiplayerTransportEvent> {
            stream
        }

        public func start(configuration: MultiplayerTransportConfiguration) async throws {
            guard self.configuration == nil else { return }
            self.configuration = configuration
            switch mode {
            case let .host(serviceName):
                guard configuration.role == .host else { throw MultiplayerError.hostOnly }
                let listener = try NWListener(using: parameters())
                listener.service = NWListener.Service(
                    name: serviceName,
                    type: AppleLocalDiscovery.serviceType
                )
                listener.newConnectionHandler = { [weak self] connection in
                    Task { await self?.accept(connection) }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    if case let .failed(error) = state {
                        Task { await self?.fail(error.localizedDescription) }
                    }
                }
                self.listener = listener
                listener.start(queue: .global(qos: .userInitiated))
            case let .peer(endpoint):
                guard configuration.role == .peer else { throw MultiplayerError.peerOnly }
                let channel = AppleLocalChannel(
                    NWConnection(to: endpoint, using: parameters())
                )
                await channel.start()
                try await channel.send(try JSONEncoder().encode(configuration.localPeerID))
                let hostID = try JSONDecoder().decode(PeerID.self, from: await channel.receive())
                attach(channel, peer: hostID)
            }
        }

        public func send(_ payload: Data, to target: NetworkTarget) async throws {
            guard let configuration else { throw MultiplayerError.notConnected }
            let recipients: [AppleLocalChannel]
            switch target {
            case .host:
                guard configuration.role == .peer, let channel = channels.values.first else {
                    throw MultiplayerError.invalidDirection
                }
                recipients = [channel]
            case let .peer(peer):
                guard configuration.role == .host, let channel = channels[peer] else {
                    throw MultiplayerError.invalidDirection
                }
                recipients = [channel]
            case .allPeers:
                guard configuration.role == .host else { throw MultiplayerError.invalidDirection }
                recipients = Array(channels.values)
            case let .allPeersExcept(excluded):
                guard configuration.role == .host else { throw MultiplayerError.invalidDirection }
                recipients = channels.compactMap { peer, channel in peer == excluded ? nil : channel }
            }
            for channel in recipients {
                try await channel.send(payload)
            }
        }

        public func stop() async {
            listener?.cancel()
            listener = nil
            for task in receiveTasks.values { task.cancel() }
            receiveTasks.removeAll()
            for channel in channels.values { await channel.stop() }
            channels.removeAll()
            configuration = nil
        }

        static func discoveryParameters() -> NWParameters {
            let options = NWProtocolQUIC.Options()
            options.direction = .bidirectional
            options.alpn = ["ada-multiplayer-v1"]
            return NWParameters(quic: options)
        }

        private func parameters() -> NWParameters {
            let options = NWProtocolQUIC.Options()
            options.direction = .bidirectional
            options.alpn = ["ada-multiplayer-v1"]
            configureQUIC(options)
            return NWParameters(quic: options)
        }

        private func accept(_ connection: NWConnection) async {
            guard let configuration else {
                connection.cancel()
                return
            }
            let channel = AppleLocalChannel(connection)
            await channel.start()
            do {
                let peerID = try JSONDecoder().decode(PeerID.self, from: await channel.receive())
                try await channel.send(try JSONEncoder().encode(configuration.localPeerID))
                attach(channel, peer: peerID)
            } catch {
                await channel.stop()
                continuation.yield(.failed(String(describing: error)))
            }
        }

        private func attach(_ channel: AppleLocalChannel, peer: PeerID) {
            channels[peer] = channel
            continuation.yield(.connected(peer))
            receiveTasks[peer] = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let payload = try await channel.receive()
                        await self?.receive(payload, source: peer)
                    }
                } catch {
                    await self?.disconnect(peer, message: String(describing: error))
                }
            }
        }

        private func receive(_ payload: Data, source: PeerID) {
            continuation.yield(.received(source: source, payload: payload))
        }

        private func disconnect(_ peer: PeerID, message _: String) async {
            receiveTasks.removeValue(forKey: peer)?.cancel()
            if let channel = channels.removeValue(forKey: peer) {
                await channel.stop()
            }
            continuation.yield(.disconnected(peer))
        }

        private func fail(_ message: String) {
            continuation.yield(.failed(message))
        }
    }
#endif
