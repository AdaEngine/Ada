import AdaEngine
import AdaMultiplayer
import Foundation

struct EditorAdaScriptMultiplayerPlugin: Plugin {
    private let settings: AdaProjectMultiplayerSettings

    init(settings: AdaProjectMultiplayerSettings) {
        self.settings = settings
    }

    @MainActor
    func setup(in app: borrowing AppWorlds) {
        let role: NetworkRole = settings.role == "peer" ? .peer : .host
        let localPeerID = Self.peerID(role: role, index: settings.peerIndex)
        let transport = LocalTCPTransport(
            host: settings.host,
            port: UInt16(settings.port),
            log: { message in
                RuntimeLogStore.shared.append(
                    level: "info",
                    label: "AdaScript.Multiplayer",
                    message: message
                )
            }
        )
        let configuration = MultiplayerConfiguration(
            role: role,
            sessionID: Self.sessionID,
            localPeerID: localPeerID,
            compatibility: NetworkCompatibility(
                gameIdentifier: settings.gameIdentifier,
                buildIdentifier: settings.buildIdentifier
            ),
            snapshotsPerSecond: 20,
            disconnectGracePeriod: 2
        )

        MultiplayerPlugin(configuration: configuration, transport: transport).setup(in: app)
        AdaScriptMultiplayerBridgePlugin(configuration: configuration).setup(in: app)

        RuntimeLogStore.shared.append(
            level: "info",
            label: "AdaScript.Multiplayer",
            message: "launch role=\(role.rawValue) peer=\(localPeerID.rawValue.uuidString)"
        )
    }

    private static let sessionID = SessionID(
        rawValue: UUID(uuid: (0x4d, 0x45, 0x44, 0x49, 0x45, 0x56, 0x41, 0x4c, 0x80, 0, 0, 0, 0, 0, 0, 1))
    )

    private static func peerID(role: NetworkRole, index: Int) -> PeerID {
        let suffix = UInt8(clamping: role == .host ? 1 : max(1, index))
        return PeerID(
            rawValue: UUID(uuid: (0x4d, 0x41, 0x50, 0x45, 0x45, 0x52, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, suffix))
        )
    }
}
