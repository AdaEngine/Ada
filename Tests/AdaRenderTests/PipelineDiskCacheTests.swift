@testable import AdaRender
import Foundation
import Testing

@Suite("Pipeline disk cache")
struct PipelineDiskCacheTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-pipeline-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func storedBlobIsLoadedByALaterCacheInstance() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data("pipeline-key".utf8)
        let value = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })

        PipelineDiskCache(directory: directory).store(key: key, value: value)

        let reopened = PipelineDiskCache(directory: directory)
        #expect(reopened.load(key: key) == value)
        #expect(reopened.statistics.hits == 1)
    }

    @Test
    func unknownKeyIsAMiss() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PipelineDiskCache(directory: directory)

        #expect(cache.load(key: Data("missing".utf8)) == nil)
        #expect(cache.statistics.misses == 1)
    }

    @Test
    func entryWhoseStoredKeyDiffersIsRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PipelineDiskCache(directory: directory)
        let key = Data("first".utf8)
        cache.store(key: key, value: Data([1, 2, 3]))

        // Simulate a file-name collision: another key's entry lands in this key's file.
        let other = PipelineDiskCache(directory: directory)
        let file = other.fileURL(for: key)
        let foreign = PipelineDiskCache.encodeEntry(key: Data("second".utf8), value: Data([9]))
        try foreign.write(to: file)

        #expect(other.load(key: key) == nil)
    }

    @Test
    func entryOfAnotherKeyIsKeptOnDisk() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PipelineDiskCache(directory: directory)
        let key = Data("mine".utf8)
        let file = cache.fileURL(for: key)
        try PipelineDiskCache.encodeEntry(key: Data("theirs".utf8), value: Data([1])).write(to: file)

        #expect(cache.load(key: key) == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func headerWithHugeLengthsIsRejectedWithoutTrapping() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PipelineDiskCache(directory: directory)
        let key = Data("huge".utf8)
        var entry = PipelineDiskCache.encodeEntry(key: key, value: Data([1, 2]))
        entry.replaceSubrange(8..<16, with: Data(repeating: 0xFF, count: 8))
        try entry.write(to: cache.fileURL(for: key))

        #expect(cache.load(key: key) == nil)
        #expect(cache.statistics.rejected == 1)
    }

    @Test
    func copyUsesTheBlobSizedByTheQueryEvenIfTheFileChangesBetween() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data("raced".utf8)
        let original = Data([1, 2, 3, 4])
        let cache = PipelineDiskCache(directory: directory)
        cache.store(key: key, value: original)

        let size = key.withUnsafeBytes { cache.load(key: $0, into: nil) }
        // Another process replaces the entry with a different size.
        try PipelineDiskCache.encodeEntry(key: key, value: Data(repeating: 9, count: 64)).write(to: cache.fileURL(for: key))
        var output = [UInt8](repeating: 0, count: size)
        let copied = key.withUnsafeBytes { keyBytes in
            output.withUnsafeMutableBytes { cache.load(key: keyBytes, into: $0) }
        }

        #expect(copied == original.count)
        #expect(Data(output) == original)
    }

    @Test
    func concurrentStoresAndLoadsStayConsistent() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PipelineDiskCache(directory: directory)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let key = Data("key-\(index % 4)".utf8)
                    cache.store(key: key, value: Data(repeating: UInt8(index % 4), count: 256))
                    _ = cache.load(key: key)
                }
            }
        }
        for index in 0..<4 {
            #expect(cache.load(key: Data("key-\(index)".utf8)) == Data(repeating: UInt8(index), count: 256))
        }
    }

    @Test
    func unusedAdapterFoldersAndAbandonedTemporaryFilesAreRemoved() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-60 * 24 * 60 * 60)
        func makeFile(_ url: URL, date: Date) throws {
            try Data([0]).write(to: url)
            try manager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let stale = root.appendingPathComponent("abc123", isDirectory: true)
        let recent = root.appendingPathComponent("def456", isDirectory: true)
        let foreign = root.appendingPathComponent("beef", isDirectory: true)
        for folder in [stale, recent, foreign] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try makeFile(stale.appendingPathComponent("1-1.bin"), date: old)
        try makeFile(recent.appendingPathComponent("2-1.bin"), date: now)
        try makeFile(foreign.appendingPathComponent("notes.txt"), date: old)
        let current = root.appendingPathComponent("0f0f", isDirectory: true)
        try manager.createDirectory(at: current, withIntermediateDirectories: true)
        try makeFile(current.appendingPathComponent("tmp-write"), date: old)

        _ = PipelineDiskCache(directory: current, now: now)

        #expect(!manager.fileExists(atPath: stale.path))
        #expect(manager.fileExists(atPath: recent.path))
        #expect(manager.fileExists(atPath: foreign.path))
        #expect(!manager.fileExists(atPath: current.appendingPathComponent("tmp-write").path))
    }

    @Test
    func truncatedEntryIsRejectedAndRemoved() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data("pipeline".utf8)
        let cache = PipelineDiskCache(directory: directory)
        cache.store(key: key, value: Data(repeating: 7, count: 512))
        let file = cache.fileURL(for: key)
        let bytes = try Data(contentsOf: file)
        try bytes.prefix(bytes.count - 100).write(to: file)

        let reopened = PipelineDiskCache(directory: directory)
        #expect(reopened.load(key: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func sizeQueryFollowedByCopyMatchesDawnsTwoStepLoad() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data("two-step".utf8)
        let value = Data([10, 20, 30, 40, 50])
        PipelineDiskCache(directory: directory).store(key: key, value: value)
        let cache = PipelineDiskCache(directory: directory)

        let size = key.withUnsafeBytes { cache.load(key: $0, into: nil) }
        #expect(size == value.count)
        var output = [UInt8](repeating: 0, count: size)
        let copied = key.withUnsafeBytes { keyBytes in
            output.withUnsafeMutableBytes { cache.load(key: keyBytes, into: $0) }
        }
        #expect(copied == value.count)
        #expect(Data(output) == value)
        // A buffer of the wrong size is refused rather than partially filled.
        var small = [UInt8](repeating: 0, count: 2)
        let refused = key.withUnsafeBytes { keyBytes in
            small.withUnsafeMutableBytes { cache.load(key: keyBytes, into: $0) }
        }
        #expect(refused == 0)
    }

    @Test
    func directoryIsPerAdapterAndCanBeOverriddenOrDisabled() {
        let caches = URL(fileURLWithPath: "/caches", isDirectory: true)
        let first = PipelineDiskCache.directory(environment: [:], cachesDirectory: caches, adapterFingerprint: "d3d12|10de|2786")
        let second = PipelineDiskCache.directory(environment: [:], cachesDirectory: caches, adapterFingerprint: "vulkan|10de|2786")

        #expect(first?.deletingLastPathComponent().path.hasSuffix("AdaEngine/PipelineCache") == true)
        #expect(first != second)
        let overridden = PipelineDiskCache.directory(
            environment: ["ADAENGINE_PIPELINE_CACHE_DIR": "/custom"],
            cachesDirectory: caches,
            adapterFingerprint: "d3d12|10de|2786"
        )
        #expect(overridden?.deletingLastPathComponent().lastPathComponent == "custom")
        #expect(PipelineDiskCache.directory(environment: ["ADAENGINE_PIPELINE_CACHE": "0"], cachesDirectory: caches, adapterFingerprint: "x") == nil)
    }

    @Test
    func oldestEntriesArePrunedWhenTheDirectoryExceedsItsBudget() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = PipelineDiskCache(directory: directory)
        for index in 0..<8 {
            writer.store(key: Data("key-\(index)".utf8), value: Data(repeating: UInt8(index), count: 1000))
            let file = writer.fileURL(for: Data("key-\(index)".utf8))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60)],
                ofItemAtPath: file.path
            )
        }

        let pruned = PipelineDiskCache(directory: directory, byteBudget: 4500)

        #expect(pruned.load(key: Data("key-0".utf8)) == nil)
        #expect(pruned.load(key: Data("key-7".utf8)) == Data(repeating: 7, count: 1000))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining.count <= 4)
    }
}
