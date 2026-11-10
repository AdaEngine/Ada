//
//  PipelineDiskCache.swift
//  AdaEngine
//

// Dawn's blob cache exists only in native builds; WASI also lacks atomic file writes.
#if !WASM
import Foundation
import Synchronization

/// Persistent key/value store backing Dawn's blob cache.
///
/// Dawn hands the embedder opaque keys and blobs (translated and compiled shaders, and
/// pipeline state where the backend supports it) through `DawnCacheDeviceDescriptor`.
/// Storing them on disk lets later launches skip shader translation and driver
/// compilation, which otherwise costs hundreds of milliseconds per pipeline variant.
///
/// Each entry is one file named by a 64-bit FNV-1a hash of the key. The file repeats
/// the full key, so a hash collision or a foreign file is a miss rather than wrong data.
/// Truncated or malformed files are deleted. The directory is trimmed to `byteBudget`
/// on creation, removing the least recently used entries first (a hit refreshes the
/// entry's modification date).
///
/// Dawn may call the cache from several threads, so all access is serialized.
final class PipelineDiskCache: Sendable {
    struct Statistics: Equatable {
        var hits = 0
        var misses = 0
        var stores = 0
        var rejected = 0
    }

    static let defaultByteBudget = 512 * 1024 * 1024

    let directory: URL

    private struct State: ~Copyable {
        var statistics = Statistics()
        /// The entry found by Dawn's size query, reused by the copy that follows it.
        var lastLoaded: (key: Data, value: Data)?
    }

    private static let magic: UInt32 = 0x4350_4441 // "ADPC"
    private static let version: UInt32 = 1
    private static let headerSize = 4 + 4 + 8 + 8

    private let state = Mutex(State())

    /// Adapter folders untouched for this long are removed (a driver update changes the
    /// adapter fingerprint, which would otherwise leave the old folder behind forever).
    static let defaultStaleAdapterAge: TimeInterval = 30 * 24 * 60 * 60

    /// Leftover files from writes interrupted by a crash are removed after this age.
    private static let abandonedTemporaryFileAge: TimeInterval = 60 * 60

    init(
        directory: URL,
        byteBudget: Int = PipelineDiskCache.defaultByteBudget,
        staleAdapterAge: TimeInterval = PipelineDiskCache.defaultStaleAdapterAge,
        now: Date = Date()
    ) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.prune(directory: directory, byteBudget: byteBudget, now: now)
        Self.removeStaleSiblingAdapters(of: directory, olderThan: staleAdapterAge, now: now)
    }

    /// Resolves the cache directory for one adapter.
    ///
    /// `ADAENGINE_PIPELINE_CACHE=0` disables the cache. `ADAENGINE_PIPELINE_CACHE_DIR`
    /// replaces the default `<caches>/AdaEngine/PipelineCache`. Each adapter gets its own
    /// subdirectory so switching GPUs or backends never evicts the other's entries.
    static func directory(
        environment: [String: String],
        cachesDirectory: URL?,
        adapterFingerprint: String
    ) -> URL? {
        if let flag = environment["ADAENGINE_PIPELINE_CACHE"]?.lowercased(), ["0", "false", "off", "no"].contains(flag) {
            return nil
        }
        let root: URL
        if let override = environment["ADAENGINE_PIPELINE_CACHE_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else if let cachesDirectory {
            root = cachesDirectory
                .appendingPathComponent("AdaEngine", isDirectory: true)
                .appendingPathComponent("PipelineCache", isDirectory: true)
        } else {
            return nil
        }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in adapterFingerprint.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return root.appendingPathComponent(String(hash, radix: 16), isDirectory: true)
    }

    var statistics: Statistics {
        state.withLock { $0.statistics }
    }

    func fileURL(for key: Data) -> URL {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let name = String(hash, radix: 16) + "-" + String(key.count, radix: 16) + ".bin"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - Data API

    func load(key: Data) -> Data? {
        state.withLock { state in
            lookup(key: key, statistics: &state.statistics)
        }
    }

    func store(key: Data, value: Data) {
        let entry = Self.encodeEntry(key: key, value: value)
        state.withLock { state in
            do {
                try entry.write(to: fileURL(for: key), options: .atomic)
                state.statistics.stores += 1
                if state.lastLoaded?.key == key {
                    state.lastLoaded = nil
                }
            } catch {
                state.statistics.rejected += 1
            }
        }
    }

    // MARK: - Dawn callback API

    /// Implements `WGPUDawnLoadCacheDataFunction`.
    ///
    /// With no output buffer this returns the stored size (0 for a miss). With a buffer
    /// it copies the blob and returns its size, or returns 0 if the sizes differ.
    ///
    /// The copy is served from the entry memoized by the size query, so a file replaced
    /// by another process between the two calls cannot change the size Dawn was told.
    /// Dawn serializes these calls per device, so the memo is always the preceding query.
    func load(key: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer?) -> Int {
        let key = unsafe Data(key)
        return state.withLock { state in
            let value: Data?
            if let lastLoaded = state.lastLoaded, lastLoaded.key == key {
                value = lastLoaded.value
            } else {
                value = lookup(key: key, statistics: &state.statistics)
                state.lastLoaded = value.map { (key, $0) }
            }
            guard let value else {
                return 0
            }
            guard let output = unsafe output else {
                return value.count
            }
            state.lastLoaded = nil
            guard output.count == value.count else {
                return 0
            }
            unsafe value.copyBytes(to: output)
            return value.count
        }
    }

    /// Implements `WGPUDawnStoreCacheDataFunction`.
    func store(key: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer) {
        unsafe store(key: Data(key), value: Data(value))
    }

    // MARK: - Entries

    static func encodeEntry(key: Data, value: Data) -> Data {
        var data = Data(capacity: headerSize + key.count + value.count)
        append(magic, to: &data)
        append(version, to: &data)
        append(UInt64(key.count), to: &data)
        append(UInt64(value.count), to: &data)
        data.append(key)
        data.append(value)
        return data
    }

    private func lookup(key: Data, statistics: inout Statistics) -> Data? {
        let url = fileURL(for: key)
        guard let entry = try? Data(contentsOf: url) else {
            statistics.misses += 1
            return nil
        }
        switch Self.decodeEntry(entry, expectedKey: key) {
        case let .value(value):
            statistics.hits += 1
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return value
        case .otherKey:
            statistics.misses += 1
            return nil
        case .malformed:
            statistics.rejected += 1
            statistics.misses += 1
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private enum Decoded {
        case value(Data)
        case otherKey
        case malformed
    }

    private static func decodeEntry(_ entry: Data, expectedKey: Data) -> Decoded {
        guard entry.count >= headerSize,
              read(UInt32.self, from: entry, at: 0) == magic,
              read(UInt32.self, from: entry, at: 4) == version
        else {
            return .malformed
        }
        let keyCount = read(UInt64.self, from: entry, at: 8)
        let valueCount = read(UInt64.self, from: entry, at: 16)
        let available = UInt64(entry.count - headerSize)
        guard keyCount <= available, valueCount == available - keyCount else {
            return .malformed
        }
        let keyStart = entry.startIndex + headerSize
        let valueStart = keyStart + Int(keyCount)
        guard entry[keyStart..<valueStart] == expectedKey else {
            return .otherKey
        }
        return .value(Data(entry[valueStart..<entry.endIndex]))
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        unsafe withUnsafeBytes(of: value.littleEndian) { unsafe data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ type: T.Type, from data: Data, at offset: Int) -> T {
        var value: T = 0
        let start = data.startIndex + offset
        for index in 0..<MemoryLayout<T>.size {
            value |= T(data[start + index]) << (index * 8)
        }
        return value
    }

    // MARK: - Pruning

    private static func prune(directory: URL, byteBudget: Int, now: Date) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for url in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            let date = values.contentModificationDate ?? .distantPast
            guard url.pathExtension == "bin" else {
                // Temporary files of atomic writes interrupted by a crash.
                if now.timeIntervalSince(date) > abandonedTemporaryFileAge {
                    try? FileManager.default.removeItem(at: url)
                }
                continue
            }
            let size = values.fileSize ?? 0
            entries.append((url, size, date))
            total += size
        }
        guard total > byteBudget else {
            return
        }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > byteBudget else {
                break
            }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }

    /// Removes other adapter folders under the same root that have not been used for
    /// `age`. Only folders that look like ours (hex names holding only cache entries)
    /// are touched, so a user-chosen `ADAENGINE_PIPELINE_CACHE_DIR` root stays safe.
    private static func removeStaleSiblingAdapters(of directory: URL, olderThan age: TimeInterval, now: Date) {
        let manager = FileManager.default
        let root = directory.deletingLastPathComponent()
        guard let siblings = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for sibling in siblings where sibling.lastPathComponent != directory.lastPathComponent {
            let name = sibling.lastPathComponent
            guard (1...16).contains(name.count), name.allSatisfy(\.isHexDigit),
                  (try? sibling.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? manager.contentsOfDirectory(
                      at: sibling,
                      includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                      options: []
                  )
            else {
                continue
            }
            var newest = Date.distantPast
            var ownedOnly = true
            for file in files {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true, file.pathExtension == "bin" else {
                    ownedOnly = false
                    break
                }
                newest = max(newest, values?.contentModificationDate ?? .distantPast)
            }
            if ownedOnly, now.timeIntervalSince(newest) > age {
                try? manager.removeItem(at: sibling)
            }
        }
    }
}
#endif
