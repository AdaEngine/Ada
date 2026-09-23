import AdaMultiplayer
import AdaScriptCompilerCore
import Foundation

#if os(WASI)
    import JavaScriptKit
#endif

/// Ephemeral relay credentials supplied by the browser lobby after create/join.
/// They are never included in the exported game files or URL.
struct PlayerBrowserSession: Decodable {
    let sessionID: UUID
    let peerID: UUID
    let role: NetworkRole
    let relayURL: URL
    let connectionTicket: String

    static var soloMode: Bool {
        #if os(WASI)
            JSObject.global["__adaSoloMode"].boolean == true
        #else
            true
        #endif
    }

    static func current() throws -> Self? {
        #if os(WASI)
            guard let json = JSObject.global["__adaMultiplayerSession"].string else { return nil }
            let value = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
            guard ["wss", "ws"].contains(value.relayURL.scheme), !value.connectionTicket.isEmpty else {
                throw AdaWebPlayerProjectError.invalid("Invalid multiplayer relay session.")
            }
            return value
        #else
            return nil
        #endif
    }
}
