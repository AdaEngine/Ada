import AdaMultiplayer
import Foundation

public struct ArenaLaunchOptions: Sendable {
    public var role: NetworkRole
    public var host: String
    public var port: UInt16
    public var peerIndex: UInt8
    public var runsBot: Bool
    public var diagnosticsPath: String?

    public init(
        role: NetworkRole = .host,
        host: String = "::1",
        port: UInt16 = 37_777,
        peerIndex: UInt8 = 1,
        runsBot: Bool = false,
        diagnosticsPath: String? = nil
    ) {
        self.role = role
        self.host = host
        self.port = port
        self.peerIndex = peerIndex
        self.runsBot = runsBot
        self.diagnosticsPath = diagnosticsPath
    }

    public static var current: Self {
        parse(Array(CommandLine.arguments.dropFirst()))
    }

    public static func parse(_ arguments: [String]) -> Self {
        var result = Self()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--host":
                result.role = .host
            case "--join":
                result.role = .peer
                if arguments.indices.contains(index + 1) {
                    result.host = arguments[index + 1]
                    index += 1
                }
            case "--port":
                if arguments.indices.contains(index + 1), let port = UInt16(arguments[index + 1]) {
                    result.port = port
                    index += 1
                }
            case "--peer-index":
                if arguments.indices.contains(index + 1), let peerIndex = UInt8(arguments[index + 1]) {
                    result.peerIndex = max(1, peerIndex)
                    index += 1
                }
            case "--bot":
                result.runsBot = true
            case "--diagnostics":
                if arguments.indices.contains(index + 1) {
                    result.diagnosticsPath = arguments[index + 1]
                    index += 1
                }
            default:
                break
            }
            index += 1
        }
        return result
    }

    public var peerID: PeerID {
        switch role {
        case .host:
            PeerID(rawValue: UUID(uuid: (0x4d, 0x41, 0x48, 0x4f, 0x53, 0x54, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01)))
        case .peer:
            PeerID(rawValue: UUID(uuid: (0x4d, 0x41, 0x50, 0x45, 0x45, 0x52, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, peerIndex)))
        }
    }

    public static let sessionID = SessionID(
        rawValue: UUID(uuid: (0x4d, 0x45, 0x44, 0x49, 0x45, 0x56, 0x41, 0x4c, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01))
    )
}

public final class ArenaDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL?

    public init(path: String?) {
        self.url = path.map { URL(fileURLWithPath: $0) }
        if let url {
            try? Data().write(to: url, options: .atomic)
        }
    }

    public func record(_ message: String) {
        let line = "[MedievalArena] \(message)\n"
        print(line, terminator: "")
        guard let url, let data = line.data(using: .utf8) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            print("[MedievalArena] diagnostics write failed: \(error)")
        }
    }
}
