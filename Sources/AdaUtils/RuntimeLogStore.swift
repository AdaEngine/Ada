import Foundation
import Logging

/// Bounded diagnostic logs. All shared state is protected by `lock`; logging may occur on any executor.
public final class RuntimeLogStore: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public let cursor: Int
        public let timestamp: Double
        public let level: String
        public let label: String
        public let message: String
        public let source: String?
    }

    public struct Batch: Codable, Sendable {
        public let entries: [Entry]
        public let nextCursor: Int
        public let dropped: Int
    }

    /// Source inherited by structured work within a runtime world.
    @TaskLocal public static var currentSource: String = "Editor"

    public static let shared = RuntimeLogStore()
    private let lock = NSLock()
    private let capacity: Int
    private var entries: [Entry] = []
    private var nextCursor = 1
    private var enabled = false

    public init(capacity: Int = 2048) {
        self.capacity = max(1, min(capacity, 16384))
    }

    public func setEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.enabled = enabled
    }

    public func append(level: String, label: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else {
            return
        }
        let entry = Entry(
            cursor: nextCursor,
            timestamp: Date().timeIntervalSince1970,
            level: String(level.prefix(32)),
            label: String(label.prefix(256)),
            message: String(message.prefix(4096)),
            source: Self.currentSource
        )
        nextCursor += 1
        if entries.count == capacity {
            entries.removeFirst()
        }
        entries.append(entry)
    }

    /// An independent cursor never clears another client's entries. `dropped` reports overflow since `after`.
    public func read(after: Int = 0, limit: Int = 200) -> Batch {
        lock.lock()
        defer { lock.unlock() }
        let cursor = max(0, after)
        let first = entries.first?.cursor ?? nextCursor
        let result = Array(entries.lazy.filter { $0.cursor > cursor }.prefix(max(1, min(limit, 1000))))
        return Batch(
            entries: result,
            nextCursor: result.last?.cursor ?? min(cursor, nextCursor - 1),
            dropped: max(0, first - cursor - 1)
        )
    }
}

/// Include alongside the normal console handler in a host that bootstraps swift-log itself.
public struct RuntimeLogHandler: LogHandler {
    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level = .trace
    private let label: String
    private let store: RuntimeLogStore

    public init(label: String, store: RuntimeLogStore = .shared) {
        self.label = label
        self.store = store
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        store.append(level: event.level.rawValue, label: label, message: event.message.description)
    }
}
