import Foundation

#if os(macOS)
    import ACPModel

    enum EditorAgentMCPConnection {
        static let bridgeArgument = "--editor-mcp-stdio"

        static func servers(
            enabled: Bool,
            supportsHTTP: Bool,
            executablePath: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        ) -> [MCPServerConfig] {
            guard enabled else {
                return []
            }
            if supportsHTTP {
                return [.http(.init(name: "AdaEditor", url: EditorMCPServerAddress.url))]
            }
            // ACP requires stdio support. Reuse this executable as a bridge to the live
            // editor instead of launching another GUI with a separate project/undo history.
            return [
                .stdio(.init(
                    name: "AdaEditor",
                    command: executablePath,
                    args: [bridgeArgument, "--mcp-port=\(EditorMCPServerAddress.port)"],
                    env: []
                ))
            ]
        }
    }

    /// Bridges newline-delimited MCP stdio to the editor's session-based HTTP server.
    /// This mode runs before AppRuntime and writes only JSON-RPC messages to stdout.
    actor EditorAgentMCPStdioBridge {
        private let endpoint: URL?
        private let session: URLSession
        private var sessionID: String?
        private var protocolVersion: String?

        init(endpoint: URL?) {
            self.endpoint = endpoint
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 300
            self.session = URLSession(configuration: configuration)
        }

        func run() async throws {
            do {
                for try await line in FileHandle.standardInput.bytes.lines where !line.isEmpty {
                    let response = await forward(Data(line.utf8))
                    if let response {
                        try FileHandle.standardOutput.write(contentsOf: response + Data([10]))
                    }
                }
            } catch {
                await disconnect()
                throw error
            }
            await disconnect()
        }

        func forward(_ data: Data) async -> Data? {
            var requestID: Any?
            do {
                guard data.count <= 16 * 1024 * 1024,
                    let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { throw BridgeError.invalidMessage }
                requestID = message["id"]
                guard let endpoint else { throw BridgeError.invalidEndpoint }
                if message["method"] as? String == "initialize" {
                    protocolVersion = (message["params"] as? [String: Any])?["protocolVersion"] as? String
                }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.httpBody = data
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
                request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
                let (body, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw BridgeError.invalidResponse }
                if let value = http.value(forHTTPHeaderField: "MCP-Session-Id") { sessionID = value }
                guard (200..<300).contains(http.statusCode) else { throw BridgeError.httpStatus(http.statusCode) }
                guard requestID != nil, !body.isEmpty else {
                    return nil
                }
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                let payload: Data
                if contentType.hasPrefix("text/event-stream") {
                    guard let text = String(data: body, encoding: .utf8) else { throw BridgeError.invalidResponse }
                    let lines = text.components(separatedBy: .newlines)
                    let values = lines.filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                    payload = Data(values.joined(separator: "\n").utf8)
                } else {
                    payload = body
                }
                let object = try JSONSerialization.jsonObject(with: payload)
                if message["method"] as? String == "initialize",
                    let result = (object as? [String: Any])?["result"] as? [String: Any],
                    let version = result["protocolVersion"] as? String {
                    protocolVersion = version
                }
                return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            } catch {
                guard let requestID else {
                    return nil
                }
                return try? JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "id": requestID,
                    "error": ["code": -32603, "message": "Ada Editor MCP connection failed: \(error.localizedDescription)"]
                ])
            }
        }

        func disconnect() async {
            if let endpoint, let sessionID {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "DELETE"
                request.timeoutInterval = 3
                request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
                request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
                _ = try? await session.data(for: request)
            }
            session.invalidateAndCancel()
        }

        private enum BridgeError: Error, LocalizedError {
            case invalidEndpoint
            case invalidMessage
            case invalidResponse
            case httpStatus(Int)

            var errorDescription: String? {
                switch self {
                case .invalidEndpoint: "Invalid editor MCP endpoint."
                case .invalidMessage: "Invalid JSON-RPC message."
                case .invalidResponse: "Invalid editor MCP response."
                case let .httpStatus(status): "Editor MCP returned HTTP \(status)."
                }
            }
        }
    }
#endif
