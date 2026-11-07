@_spi(Internal) import AdaAssets
import Foundation

/// One ledger spans both optional derived resources and subsequent material preparation.
struct ModelSidecarBudget {
    private let limits: ModelImportLimits?
    private(set) var footprint: ModelImportFootprint?

    init(footprint: ModelImportFootprint?) {
        limits = ModelImportContext.limits
        self.footprint = footprint
    }

    mutating func decode<Value>(_ url: URL, maximumBytes: Int, using parse: (Data) throws -> Value) throws -> Value {
        let previous = footprint
        let data = try read(url, maximumBytes: maximumBytes)
        do {
            return try parse(data)
        } catch {
            if let previous, let current = footprint {
                // Encoded I/O remains charged, but rejected parsed records are no longer retained.
                footprint = .init(encodedBytes: current.encodedBytes, decodedBytes: previous.decodedBytes)
            }
            throw error
        }
    }

    mutating func read(_ url: URL, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        if let root = AssetsManager.restrictedResourceRoot {
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            let canonicalTarget = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalTarget.hasPrefix(canonicalRoot + "/") else {
                throw AssetError.message("Derived model resource escapes the resource root")
            }
        }
        var cap = maximumBytes
        if let limits, let footprint {
            guard footprint.encodedBytes >= 0, footprint.encodedBytes <= limits.maximumEncodedBytes,
                footprint.decodedBytes >= 0, footprint.decodedBytes <= limits.maximumDecodedBytes
            else {
                throw ModelImportLimitError.invalidLimits
            }
            // Covers encoded bytes, parsed records, key sets, validation scratch and derived GPU copies.
            cap = min(cap, limits.maximumEncodedBytes - footprint.encodedBytes, (limits.maximumDecodedBytes - footprint.decodedBytes) / 16)
        } else if limits != nil {
            throw AssetError.message("Bounded model import is missing its resource footprint")
        }
        #if WASM
            throw AssetError.message("Synchronous derived model reads are unavailable in the browser")
        #else
            guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw AssetError.notExistAtPath(url.path)
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard try handle.seekToEnd() <= UInt64(cap) else {
                throw AssetError.message("Derived model data exceed the import budget")
            }
            try handle.seek(toOffset: 0)
            var data = Data()
            while true {
                try Task.checkCancellation()
                let remaining = cap - data.count
                let count = remaining >= 65_536 ? 65_536 : remaining + 1
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                guard chunk.count <= remaining else {
                    throw AssetError.message("Derived model data exceed the import budget")
                }
                data.append(chunk)
            }
            if let previous = footprint, limits != nil {
                footprint = .init(encodedBytes: previous.encodedBytes + data.count, decodedBytes: previous.decodedBytes + data.count * 16)
            }
            return data
        #endif
    }
}
