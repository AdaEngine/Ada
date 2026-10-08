import Foundation

/// Incremental JSONL framing for arbitrary byte chunks, preserving UTF-8 across chunk boundaries.
/// Deliver successful frames to `A2UIClient.receive` in order and report failures to the host.
public struct A2UIJSONLDecoder: Sendable {
    private var pending = Data()
    private var droppingOversizedLine = false
    public let maximumMessageBytes: Int

    public init(maximumMessageBytes: Int = 1_048_576) {
        self.maximumMessageBytes = max(1, maximumMessageBytes)
    }

    /// Oversized lines produce one failure and are discarded through their next newline.
    /// Valid envelopes before and after a bad line in the same chunk remain available.
    public mutating func append(_ chunk: Data) -> [Result<Data, A2UIValidationError>] {
        var frames: [Result<Data, A2UIValidationError>] = []
        for byte in chunk {
            if byte == 10 {
                if !droppingOversizedLine, !pending.isEmpty {
                    if pending.last == 13 { pending.removeLast() }
                    if !pending.isEmpty { frames.append(.success(pending)) }
                }
                pending.removeAll(keepingCapacity: true)
                droppingOversizedLine = false
            } else if !droppingOversizedLine {
                if pending.count < maximumMessageBytes || (byte == 13 && pending.count == maximumMessageBytes) {
                    pending.append(byte)
                } else {
                    frames.append(.failure(A2UIValidationError(message: "JSONL message exceeds the byte limit.")))
                    droppingOversizedLine = true
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
        return frames
    }

    /// Returns the final unterminated line, if present, at transport EOF.
    public mutating func finish() -> Data? {
        defer { pending.removeAll(keepingCapacity: true); droppingOversizedLine = false }
        return pending.isEmpty ? nil : pending
    }
}
