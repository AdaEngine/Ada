import Foundation

/// Codec used for typed component and RPC payloads.
public protocol NetworkCodec: Sendable {
    func encode<T: Encodable & Sendable>(_ value: T) throws -> Data
    func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) throws -> T
}

/// Debuggable Codable codec shipped by the first protocol version.
public struct JSONNetworkCodec: NetworkCodec {
    public init() {}

    public func encode<T: Encodable & Sendable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

enum NetworkFrameKind: String, Codable, Sendable {
    case handshake
    case handshakeAccepted
    case protocolError
    case snapshot
    case command
    case event
    case request
    case response
}

struct NetworkFrame: Codable, Sendable {
    var kind: NetworkFrameKind
    var epoch: UInt32 = 0
    var sequence: UInt64 = 0
    var simulationTick: UInt64 = 0
    var typeID: String?
    var typeVersion: UInt16?
    var correlationID: UUID?
    var payload: Data
}

struct NetworkHandshake: Codable, Sendable {
    var compatibility: NetworkCompatibility
    var role: NetworkRole
    var sessionID: SessionID
    var peerID: PeerID
}

struct NetworkProtocolFailure: Codable, Sendable {
    var code: String
    var message: String
}

struct NetworkSnapshot: Codable, Sendable {
    var baseline: Bool
    var entities: [NetworkEntityDelta]
}

struct NetworkEntityDelta: Codable, Sendable {
    var id: NetworkEntityID
    var name: String
    var despawned: Bool
    var components: [NetworkComponentDelta]
}

struct NetworkComponentDelta: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case set
        case remove
    }

    var typeID: String
    var version: UInt16
    var operation: Operation
    var payload: Data?
}

/// Binary framing used on every transport. The body stays Codable JSON in v1,
/// while the fixed header permits codec negotiation in a future major version.
enum NetworkWireCodec {
    private static let magic: [UInt8] = [0x41, 0x44, 0x4D, 0x50] // ADMP
    private static let maximumBodySize = 8 * 1_024 * 1_024

    static func encode(_ frame: NetworkFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(frame)
        guard body.count <= maximumBodySize else {
            throw MultiplayerError.invalidPayload
        }

        var data = Data(magic)
        append(UInt16(1), to: &data)
        append(UInt16(0), to: &data)
        append(UInt32(body.count), to: &data)
        data.append(body)
        return data
    }

    static func decode(_ data: Data) throws -> NetworkFrame {
        guard data.count >= 12, Array(data.prefix(4)) == magic else {
            throw MultiplayerError.invalidPayload
        }
        let major = readUInt16(data, at: 4)
        guard major == 1 else {
            throw MultiplayerError.incompatibleProtocol
        }
        let length = Int(readUInt32(data, at: 8))
        guard length <= maximumBodySize, data.count == 12 + length else {
            throw MultiplayerError.invalidPayload
        }
        return try JSONDecoder().decode(NetworkFrame.self, from: data.dropFirst(12))
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[data.index(data.startIndex, offsetBy: offset)]) << 8)
            | UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[data.index(data.startIndex, offsetBy: offset)]) << 24)
            | (UInt32(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 16)
            | (UInt32(data[data.index(data.startIndex, offsetBy: offset + 2)]) << 8)
            | UInt32(data[data.index(data.startIndex, offsetBy: offset + 3)])
    }
}
