import AdaApp
import AdaECS
import AdaUtils
import Foundation

/// A transport-neutral mailbox exposed to AdaScript as a reflected resource.
///
/// The bridge deliberately knows nothing about a game's entities or rules. Peers
/// publish one command payload to the host, while the host publishes one
/// authoritative snapshot payload to all peers. Payload schemas belong to the
/// AdaScript project and use detached scalar/list values.
public struct AdaScriptMultiplayerState: Resource, Sendable {
    public var role: String
    public var status: String
    public var localPeerID: String
    public var peerIDs: [String]
    public var receivedCommands: [ReflectedFieldValue]
    public var receivedSnapshot: [ReflectedFieldValue]
    public var outgoingCommand: [ReflectedFieldValue]
    public var outgoingCommandSequence: Int
    public var publishedSnapshot: [ReflectedFieldValue]
    public var publishedSnapshotSequence: Int

    public init(
        role: NetworkRole,
        localPeerID: PeerID
    ) {
        self.role = role.rawValue
        self.status = MultiplayerSessionState.idle.scriptValue
        self.localPeerID = localPeerID.rawValue.uuidString
        self.peerIDs = []
        self.receivedCommands = []
        self.receivedSnapshot = []
        self.outgoingCommand = []
        self.outgoingCommandSequence = 0
        self.publishedSnapshot = []
        self.publishedSnapshotSequence = 0
    }

    /// Registers the bridge resource and its detached AdaScript fields.
    @MainActor
    public static func registerRuntimeType() {
        RuntimeTypeRegistry.registerResource(
            Self.self,
            names: ["AdaScriptMultiplayerState", "ada.multiplayer.script-state"]
        )
        RuntimeResourceReflectionRegistry.register(
            Self.self,
            fields: [
                field(.role),
                field(.status),
                field(.localPeerID),
                field(.peerIDs),
                field(.receivedCommands),
                field(.receivedSnapshot),
                field(.outgoingCommand),
                field(.outgoingCommandSequence),
                field(.publishedSnapshot),
                field(.publishedSnapshotSequence),
            ]
        )
    }
}

/// Installs the generic AdaScript command/snapshot mailbox on top of
/// ``MultiplayerPlugin``.
public struct AdaScriptMultiplayerBridgePlugin: Plugin {
    private let configuration: MultiplayerConfiguration

    public init(configuration: MultiplayerConfiguration) {
        self.configuration = configuration
    }

    @MainActor
    public func setup(in app: borrowing AppWorlds) {
        AdaScriptMultiplayerState.registerRuntimeType()
        app
            .registerNetworkCommand(AdaScriptNetworkCommand.self)
            .registerNetworkEvent(AdaScriptNetworkSnapshot.self)
            .insertResource(
                AdaScriptMultiplayerState(
                    role: configuration.role,
                    localPeerID: configuration.localPeerID
                )
            )
            .addSystem(AdaScriptMultiplayerReceiveBridgeSystem.self, on: .networkReceive)
            .addSystem(AdaScriptMultiplayerSendBridgeSystem.self, on: .networkSend)
    }
}

struct AdaScriptNetworkCommand: NetworkCommand {
    static let networkIdentifier = "ada.script.command"

    var sequence: Int
    var payload: [ReflectedFieldValue]
}

struct AdaScriptNetworkSnapshot: NetworkEvent {
    static let networkIdentifier = "ada.script.snapshot"

    var sequence: Int
    var payload: [ReflectedFieldValue]
}

@PlainSystem(dependencies: [.after(NetworkReceiveSystem.self)])
struct AdaScriptMultiplayerReceiveBridgeSystem {
    @RemoteCommands<AdaScriptNetworkCommand>
    private var commands

    @RemoteEvents<AdaScriptNetworkSnapshot>
    private var snapshots

    @Res<MultiplayerSession>
    private var session

    @ResMut<AdaScriptMultiplayerState>
    private var state

    init(world _: World) {}

    func update(context _: UpdateContext) async {
        let sessionState = await session.currentState()
        let peers = await session.peers()
        state.status = sessionState.scriptValue
        state.peerIDs = peers.map { $0.rawValue.uuidString }.sorted()
        state.receivedCommands = commands.map { command in
            .array([
                .string(command.source.rawValue.uuidString),
                .int(command.value.sequence),
                .array(command.value.payload),
            ])
        }
        if let latest = snapshots.max(by: { $0.value.sequence < $1.value.sequence }) {
            state.receivedSnapshot = latest.value.payload
        }
    }
}

@PlainSystem
struct AdaScriptMultiplayerSendBridgeSystem {
    @Res<MultiplayerSession>
    private var session

    @Res<AdaScriptMultiplayerState>
    private var state

    @Local
    private var lastCommandSequence = 0

    @Local
    private var lastSnapshotSequence = 0

    init(world _: World) {}

    func update(context _: UpdateContext) async {
        guard await session.currentState() == .connected else {
            return
        }
        if state.role == NetworkRole.peer.rawValue,
            state.outgoingCommandSequence > lastCommandSequence {
            do {
                try await session.sendCommand(
                    AdaScriptNetworkCommand(
                        sequence: state.outgoingCommandSequence,
                        payload: state.outgoingCommand
                    )
                )
                lastCommandSequence = state.outgoingCommandSequence
            } catch MultiplayerError.notConnected {
                return
            } catch {
                RuntimeLogStore.shared.append(
                    level: "error",
                    label: "AdaScript.Multiplayer",
                    message: "Command send failed: \(error)"
                )
            }
        }
        if state.role == NetworkRole.host.rawValue,
            state.publishedSnapshotSequence > lastSnapshotSequence {
            do {
                try await session.sendEvent(
                    AdaScriptNetworkSnapshot(
                        sequence: state.publishedSnapshotSequence,
                        payload: state.publishedSnapshot
                    )
                )
                lastSnapshotSequence = state.publishedSnapshotSequence
            } catch MultiplayerError.notConnected {
                return
            } catch {
                RuntimeLogStore.shared.append(
                    level: "error",
                    label: "AdaScript.Multiplayer",
                    message: "Snapshot send failed: \(error)"
                )
            }
        }
    }
}

private extension MultiplayerSessionState {
    var scriptValue: String {
        switch self {
        case .idle: "idle"
        case .connecting: "connecting"
        case .connected: "connected"
        case .ended: "ended"
        }
    }
}

private extension AdaScriptMultiplayerState {
    enum Field: String, Sendable {
        case role, status, localPeerID, peerIDs
        case receivedCommands, receivedSnapshot
        case outgoingCommand, outgoingCommandSequence
        case publishedSnapshot, publishedSnapshotSequence

        var isWritable: Bool {
            switch self {
            case .outgoingCommand, .outgoingCommandSequence, .publishedSnapshot, .publishedSnapshotSequence: true
            default: false
            }
        }
    }

    static func field(_ field: Field) -> ReflectedComponentField {
        let writePointer: (@Sendable (UnsafeMutableRawPointer, ReflectedFieldValue) -> Bool)?
        if field.isWritable {
            unsafe writePointer = { pointer, value in
                unsafe write(value, to: field, state: pointer.assumingMemoryBound(to: Self.self))
            }
        } else {
            unsafe writePointer = nil
        }
        return unsafe ReflectedComponentField(
            key: field.rawValue,
            label: field.rawValue,
            kind: .readOnly,
            isWritable: field.isWritable,
            accepts: { value in accepts(value, for: field) },
            read: { _ in nil },
            write: { _, _ in nil },
            readPointer: { pointer in
                read(field, from: unsafe pointer.assumingMemoryBound(to: Self.self).pointee)
            },
            writePointer: writePointer
        )
    }

    static func accepts(_ value: ReflectedFieldValue, for field: Field) -> Bool {
        switch field {
        case .outgoingCommand, .publishedSnapshot:
            if case .array = value { true } else { false }
        case .outgoingCommandSequence, .publishedSnapshotSequence:
            if case .int = value { true } else { false }
        default:
            false
        }
    }

    static func read(_ field: Field, from state: Self) -> ReflectedFieldValue {
        switch field {
        case .role: .string(state.role)
        case .status: .string(state.status)
        case .localPeerID: .string(state.localPeerID)
        case .peerIDs: .array(state.peerIDs.map(ReflectedFieldValue.string))
        case .receivedCommands: .array(state.receivedCommands)
        case .receivedSnapshot: .array(state.receivedSnapshot)
        case .outgoingCommand: .array(state.outgoingCommand)
        case .outgoingCommandSequence: .int(state.outgoingCommandSequence)
        case .publishedSnapshot: .array(state.publishedSnapshot)
        case .publishedSnapshotSequence: .int(state.publishedSnapshotSequence)
        }
    }

    static func write(
        _ value: ReflectedFieldValue,
        to field: Field,
        state: UnsafeMutablePointer<Self>
    ) -> Bool {
        switch (field, value) {
        case let (.outgoingCommand, .array(values)):
            unsafe state.pointee.outgoingCommand = values
        case let (.outgoingCommandSequence, .int(value)):
            unsafe state.pointee.outgoingCommandSequence = value
        case let (.publishedSnapshot, .array(values)):
            unsafe state.pointee.publishedSnapshot = values
        case let (.publishedSnapshotSequence, .int(value)):
            unsafe state.pointee.publishedSnapshotSequence = value
        default:
            return false
        }
        return true
    }
}
