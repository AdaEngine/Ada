import AdaECS
import protocol AdaUtils.DefaultValue
import Foundation

/// Stable identifier for a multiplayer session.
public struct SessionID: Codable, Hashable, RawRepresentable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }
}

/// Stable identifier for one participant in a multiplayer session.
public struct PeerID: Codable, Hashable, RawRepresentable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }
}

/// Stable network identity assigned by the authoritative host.
public struct NetworkEntityID: Codable, Hashable, RawRepresentable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }
}

/// The local runtime role in a star-shaped multiplayer session.
public enum NetworkRole: String, Codable, Sendable {
    case host
    case peer
}

/// Destination for a packet sent through a multiplayer transport.
public enum NetworkTarget: Codable, Equatable, Sendable {
    case host
    case peer(PeerID)
    case allPeers
    case allPeersExcept(PeerID)
}

/// Compatibility data exchanged before any gameplay state is accepted.
public struct NetworkCompatibility: Codable, Equatable, Sendable {
    public var protocolMajor: UInt16
    public var protocolMinor: UInt16
    public var gameIdentifier: String
    public var buildIdentifier: String
    public var schemaDigest: String

    public init(
        protocolMajor: UInt16 = 1,
        protocolMinor: UInt16 = 0,
        gameIdentifier: String,
        buildIdentifier: String,
        schemaDigest: String = ""
    ) {
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.gameIdentifier = gameIdentifier
        self.buildIdentifier = buildIdentifier
        self.schemaDigest = schemaDigest
    }
}

/// Runtime configuration for ``MultiplayerPlugin``.
public struct MultiplayerConfiguration: Sendable {
    public var role: NetworkRole
    public var sessionID: SessionID
    public var localPeerID: PeerID
    public var compatibility: NetworkCompatibility
    public var snapshotsPerSecond: Double
    public var disconnectGracePeriod: TimeInterval

    public init(
        role: NetworkRole,
        sessionID: SessionID = SessionID(),
        localPeerID: PeerID = PeerID(),
        compatibility: NetworkCompatibility,
        snapshotsPerSecond: Double = 20,
        disconnectGracePeriod: TimeInterval = 10
    ) {
        self.role = role
        self.sessionID = sessionID
        self.localPeerID = localPeerID
        self.compatibility = compatibility
        self.snapshotsPerSecond = max(1, snapshotsPerSecond)
        self.disconnectGracePeriod = max(0, disconnectGracePeriod)
    }
}

/// Marker placed on an entity that participates in network replication.
///
/// The host fills ``id`` on the first network snapshot. Only component types
/// registered with `registerReplicatedComponent` are serialized.
public struct ReplicatedEntity: Component, Codable, DefaultValue, Sendable {
    public static var requiredComponents: RequiredComponents {
        RequiredComponents(components: [])
    }

    public var id: NetworkEntityID?

    public init(id: NetworkEntityID? = nil) {
        self.id = id
    }

    public static var defaultValue: Self {
        Self()
    }
}

/// Identifies the peer whose input controls an entity.
///
/// This does not transfer authoritative component mutation away from the host.
public struct NetworkOwner: Component, Codable, Sendable {
    public static var requiredComponents: RequiredComponents {
        RequiredComponents(components: [])
    }

    public var peer: PeerID

    public init(peer: PeerID) {
        self.peer = peer
    }
}

/// High-level state exposed by ``MultiplayerSession``.
public enum MultiplayerSessionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case ended(MultiplayerSessionEndReason)
}

/// Reason an active multiplayer session ended.
public enum MultiplayerSessionEndReason: Equatable, Sendable {
    case stopped
    case hostDisconnected
    case transportFailure(String)
    case incompatiblePeer(PeerID)
}

/// Errors produced by the public multiplayer API.
public enum MultiplayerError: Error, Equatable, Sendable {
    case notConnected
    case hostOnly
    case peerOnly
    case incompatibleProtocol
    case incompatibleSchema
    case unknownMessage(String)
    case invalidDirection
    case invalidPayload
    case requestTimedOut
    case sessionEnded
    case unsupportedPlatform
}
