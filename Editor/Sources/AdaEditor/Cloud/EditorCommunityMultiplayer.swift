@_spi(Internal) import AdaApp
import AdaEngine
import AdaMultiplayer
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct EditorCommunityRoom: Sendable {
    let sessionID: UUID
    let peerID: UUID
    let joinCode: String?
    let relay: CloudRelayCredentials
    let role: NetworkRole
    let gameID: String
    let buildID: String
}

@MainActor
struct EditorCommunityMultiplayerClient {
    typealias API = @MainActor @Sendable (String, EditorCloudValue, Bool) async throws -> EditorCloudValue
    let server: URL
    var api: API?

    func create(gameID: String, buildID: String) async throws -> EditorCommunityRoom {
        let value = try await request("/multiplayer/sessions", ["gameID": .string(gameID), "buildID": .string(buildID)], authenticated: true)
        return try room(value, role: .host, gameID: gameID, buildID: buildID)
    }

    func join(code: String, gameID: String, buildID: String) async throws -> EditorCommunityRoom {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 8, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw MultiplayerError.invalidPayload }
        let value = try await request("/multiplayer/join", ["joinCode": .string(code), "gameID": .string(gameID), "buildID": .string(buildID)], authenticated: false)
        return try room(value, role: .peer, gameID: gameID, buildID: buildID)
    }

    private func request(_ path: String, _ body: EditorCloudValue, authenticated: Bool) async throws -> EditorCloudValue {
        if let api { return try await api(path, body, authenticated) }
        if authenticated {
            let account = EditorCloudAccount.shared
            guard account.server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), account.accountID != nil else {
                throw EditorCommunityMultiplayerError.signInRequired
            }
            return try await account.request(path, method: "POST", body: body)
        }
        var request = URLRequest(url: server.appendingPathComponent("v1" + path))
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await EditorCommunityHTTP.fetch(request)
        guard response.statusCode == 200 else { throw EditorCommunityMultiplayerError.unavailable }
        return try JSONDecoder().decode(EditorCloudValue.self, from: data)
    }

    private func room(_ value: EditorCloudValue, role: NetworkRole, gameID: String, buildID: String) throws -> EditorCommunityRoom {
        guard value["gameID"].string == gameID, value["buildID"].string == buildID,
              let sid = value["sessionID"].string.flatMap(UUID.init(uuidString:)),
              let peer = value["peerID"].string.flatMap(UUID.init(uuidString:)),
              let ticket = value["connectionTicket"].string, !ticket.isEmpty, ticket.utf8.count <= 1024,
              let address = value["relayURL"].string, let relay = URL(string: address), relay.host != nil,
              relay.user == nil, relay.password == nil, relay.query == nil, relay.fragment == nil,
              relay.scheme == "wss" || (relay.scheme == "ws" && server.scheme == "http" && relay.host == server.host && ["127.0.0.1", "localhost"].contains(relay.host ?? "")),
              value["expiresAt"].seconds > Date().timeIntervalSince1970 else { throw EditorCommunityMultiplayerError.unavailable }
        let code = value["joinCode"].string
        if role == .host, code?.count != 8 { throw EditorCommunityMultiplayerError.unavailable }
        return EditorCommunityRoom(sessionID: sid, peerID: peer, joinCode: code, relay: .init(url: relay, connectionTicket: ticket), role: role, gameID: gameID, buildID: buildID)
    }
}

enum EditorCommunityMultiplayerError: Error, LocalizedError {
    case signInRequired
    case unavailable
    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to Ada Cloud in Studio settings before hosting a room."
        case .unavailable: "This room is unavailable or runs another game version."
        }
    }
}

struct EditorCommunityNetworkPlugin: Plugin {
    let configuration: MultiplayerConfiguration
    let transport: any MultiplayerTransport
    func setup(in app: borrowing AppWorlds) {
        MultiplayerPlugin(configuration: configuration, transport: transport).setup(in: app)
        AdaScriptMultiplayerBridgePlugin(configuration: configuration).setup(in: app)
    }
    func destroy(for app: borrowing AppWorlds) {
        if let session = app.getResource(MultiplayerSession.self) { Task { await session.stop() } }
        else { Task { await transport.stop() } }
    }
}

struct EditorCommunityScriptsPlugin: Plugin {
    let catalog: AdaScriptObjectCatalog
    @MainActor func setup(in app: borrowing AppWorlds) {
        do {
            try ScriptableObjectRegistry.install(catalog.descriptors, in: app.executionID)
            ScriptableObjectPlugin().setup(in: app)
        } catch { RuntimeLogStore.shared.append(level: "error", label: "Community", message: error.localizedDescription) }
    }
    func destroy(for app: borrowing AppWorlds) { ScriptableObjectRegistry.removeScope(app.executionID) }
}
