#if os(WASI)
    import Foundation
    import JavaScriptFoundationCompat
    import JavaScriptKit

    /// Browser implementation of the AdaEngine Cloud WebSocket transport.
    public actor CloudWebSocketTransport: MultiplayerTransport {
        public nonisolated let capabilities: MultiplayerTransportCapabilities = [.reliableOrdered]

        private let credentials: CloudRelayCredentials
        private let stream: AsyncStream<MultiplayerTransportEvent>
        private let continuation: AsyncStream<MultiplayerTransportEvent>.Continuation
        private var configuration: MultiplayerTransportConfiguration?
        private var socket: JSObject?
        private var closures: [JSClosure] = []

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
            guard self.configuration == nil else { return }
            guard credentials.url.scheme == "wss" || credentials.url.scheme == "ws",
                let constructor = JSObject.global.WebSocket.function
            else {
                throw MultiplayerError.unsupportedPlatform
            }
            self.configuration = configuration
            let socket = constructor.new(credentials.url.absoluteString)
            socket["binaryType"] = .string("arraybuffer")
            self.socket = socket

            let open = JSClosure { [weak self] _ in
                Task { await self?.opened() }
                return .undefined
            }
            let message = JSClosure { [weak self] arguments in
                guard let event = arguments.first?.object else { return .undefined }
                let value = event["data"]
                if let text = value.string {
                    Task { await self?.receiveText(text) }
                } else if let object = value.object,
                    let constructor = JSObject.global.Uint8Array.function {
                    let array = JSUint8Array(unsafelyWrapping: constructor.new(object))
                    if let data = Data.construct(from: array) {
                        Task { await self?.receiveData(data) }
                    }
                }
                return .undefined
            }
            let close = JSClosure { [weak self] _ in
                Task { await self?.failed("Cloud relay closed the WebSocket") }
                return .undefined
            }
            let error = JSClosure { [weak self] _ in
                Task { await self?.failed("Cloud relay WebSocket failed") }
                return .undefined
            }
            closures = [open, message, close, error]
            socket["onopen"] = .object(open)
            socket["onmessage"] = .object(message)
            socket["onclose"] = .object(close)
            socket["onerror"] = .object(error)
        }

        public func send(_ payload: Data, to target: NetworkTarget) async throws {
            let route: (String, UUID?) = switch target {
            case .host: ("host", nil)
            case let .peer(peer): ("peer", peer.rawValue)
            case .allPeers: ("allPeers", nil)
            case let .allPeersExcept(peer): ("allPeersExcept", peer.rawValue)
            }
            try send(
                JSONEncoder().encode(
                    CloudRelayPacket(
                        source: nil,
                        target: route.0,
                        peerID: route.1,
                        payload: payload
                    )
                )
            )
        }

        public func stop() async {
            _ = socket?.close?()
            socket = nil
            closures.removeAll()
            configuration = nil
        }

        private func opened() {
            guard let configuration else { return }
            do {
                let hello = CloudRelayHello(
                    ticket: credentials.connectionTicket,
                    sessionID: configuration.sessionID.rawValue,
                    peerID: configuration.localPeerID.rawValue,
                    role: configuration.role
                )
                try send(String(decoding: JSONEncoder().encode(hello), as: UTF8.self))
            } catch {
                failed(String(describing: error))
            }
        }

        private func receiveText(_ text: String) {
            do {
                let control = try JSONDecoder().decode(CloudRelayControl.self, from: Data(text.utf8))
                switch control.kind {
                case "ready", "connected":
                    if let peer = control.peerID {
                        continuation.yield(.connected(PeerID(rawValue: peer)))
                    }
                case "disconnected":
                    if let peer = control.peerID {
                        continuation.yield(.disconnected(PeerID(rawValue: peer)))
                    }
                case "ended", "error":
                    continuation.yield(.failed(control.message ?? "Cloud relay ended the session"))
                default:
                    throw MultiplayerError.invalidPayload
                }
            } catch {
                failed(String(describing: error))
            }
        }

        private func receiveData(_ data: Data) {
            do {
                let packet = try JSONDecoder().decode(CloudRelayPacket.self, from: data)
                guard let source = packet.source else { throw MultiplayerError.invalidPayload }
                continuation.yield(
                    .received(source: PeerID(rawValue: source), payload: packet.payload)
                )
            } catch {
                failed(String(describing: error))
            }
        }

        private func send(_ text: String) throws {
            guard let socket, let send: ((any ConvertibleToJSValue...) -> JSValue) = socket.send else {
                throw MultiplayerError.notConnected
            }
            _ = send(text)
        }

        private func send(_ data: Data) throws {
            guard let socket, let send: ((any ConvertibleToJSValue...) -> JSValue) = socket.send else {
                throw MultiplayerError.notConnected
            }
            _ = send(data.jsTypedArray.jsValue)
        }

        private func failed(_ message: String) {
            continuation.yield(.failed(message))
        }
    }
#endif
