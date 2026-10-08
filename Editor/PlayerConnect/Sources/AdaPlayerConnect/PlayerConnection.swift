import Foundation
import Network

/// One ordered TCP stream. Only one receive loop may read a connection at a time.
@MainActor
public final class PlayerConnection {
    nonisolated public static let serviceType = "_adaplayer._tcp"
    nonisolated public static let maximumFrameBytes = 96 * 1024 * 1024
    private let connection: NWConnection
    public var onFailure: ((String) -> Void)?

    public init(_ connection: NWConnection) { self.connection = connection }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in self?.onFailure?(error.localizedDescription) }
            }
        }
        connection.start(queue: .main)
    }

    public func cancel() { connection.cancel() }

    public func send(_ message: PlayerMessage) async throws {
        let frame = try await Self.encodeFrame(message)
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    public func receive(maximumBytes: Int = maximumFrameBytes) async throws -> PlayerMessage {
        let header = try await read(count: 4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumBytes else { throw PlayerConnectError.invalid("Invalid message size.") }
        let payload = try await read(count: count)
        let message = try await Self.decode(payload)
        guard message.version == 1 else { throw PlayerConnectError.invalid("AdaPlayer protocol version mismatch. Update both apps.") }
        return message
    }

    @concurrent private static func encodeFrame(_ message: PlayerMessage) async throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= Self.maximumFrameBytes else { throw PlayerConnectError.invalid("Message is too large.") }
        let count = UInt32(payload.count)
        var frame = Data([UInt8(count >> 24), UInt8(truncatingIfNeeded: count >> 16), UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])
        frame.append(payload)
        return frame
    }

    @concurrent private static func decode(_ payload: Data) async throws -> PlayerMessage {
        try JSONDecoder().decode(PlayerMessage.self, from: payload)
    }

    private func read(count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 64 * 1024)) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: PlayerConnectError.invalid(complete ? "Device disconnected." : "Empty network response.")) }
                }
            }
            result.append(chunk)
        }
        return result
    }
}
