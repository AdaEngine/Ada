#if os(Windows)
import Dispatch
import Foundation
import WinSDK

/// All writes and close operations share one serial queue. A full stdin pipe never
/// blocks the ACP actor, so it can keep draining stdout and processing cancellation.
actor EditorWindowsACPWriter {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "org.adaengine.acp.stdin")

    init(_ handle: FileHandle) { self.handle = handle }

    func write(_ data: Data) async throws {
        let handle = self.handle
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try handle.write(contentsOf: data)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func close() async {
        let handle = self.handle
        await withCheckedContinuation { continuation in
            queue.async {
                try? handle.close()
                continuation.resume()
            }
        }
    }
}

enum EditorWindowsACPTransport {
    static let maximumMessageBytes = 16 * 1024 * 1024

    static let maximumChunkBytes = 64 * 1024

    /// Read only when the consumer requests another chunk. The OS pipe provides
    /// backpressure while parsing is busy, without dropping protocol bytes or
    /// growing an in-memory queue. Blocking pipe I/O stays off Swift's executor.
    static func chunks(_ handle: FileHandle) -> AsyncThrowingStream<Data, any Error> {
        let queue = DispatchQueue(label: "org.adaengine.acp.stdout")
        return AsyncThrowingStream(unfolding: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        continuation.resume(returning: try readChunk(handle))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        })
    }

    private static func readChunk(_ handle: FileHandle) throws -> Data? {
        // Foundation's read(upToCount:) waits to fill the requested length on
        // Windows. One ReadFile returns as soon as a byte-stream pipe has data,
        // so short JSON-RPC requests do not wait for another message or EOF.
        var data = Data(count: maximumChunkBytes)
        var count: DWORD = 0
        var failure: DWORD = 0
        let succeeded = data.withUnsafeMutableBytes { bytes in
            let result = ReadFile(handle._handle, bytes.baseAddress, DWORD(bytes.count), &count, nil)
            if !result { failure = GetLastError() }
            return result
        }
        guard succeeded else {
            if failure == ERROR_BROKEN_PIPE || failure == ERROR_NO_DATA { return nil }
            throw NSError(domain: "org.adaengine.acp.pipe", code: Int(failure))
        }
        guard count > 0 else { return nil }
        data.count = Int(count)
        return data
    }
}
#endif
