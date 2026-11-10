//
//  ShaderCache.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/17/23.
//

import AdaUtils
import Foundation
import Logging
import Synchronization

#if !WASM
    @unsafe @preconcurrency import Yams
#endif

/// Contains information about shader changes and store/load spirv binary in cache folder.
enum ShaderCache {
    typealias Cache = [String: [ShaderStage: ShaderCache]]

    struct ShaderCache: Equatable, Codable {
        let sourceHashValue: Int
        let headers: [ShaderSource.IncludeSearchPath]
        let version: Int
    }

    private static let fileSystem = FileSystem.current
    private static let logger = Logger(label: "org.adaengine.shader-cache")
    private static let cachedManifest = Mutex<Cache?>(nil)

    /// Hash of a stage's source with its includes expanded, so editing an included file invalidates every
    /// shader that uses it. When an include cannot be resolved the raw text is hashed and compilation reports
    /// the error later.
    static func hashValue(of source: String, includeSearchPaths: [ShaderSource.IncludeSearchPath]) -> Int {
        let expanded = (try? ShaderIncluder.processIncludes(in: source, includeSearchPath: includeSearchPaths)) ?? source
        return expanded.uniqueHashValue
    }

    /// - Parameter includeSearchPaths: Every path the compiler resolves includes through. The compiler adds
    ///   the engine's own `AdaEngine` module itself, so callers that compile should pass its full list;
    ///   otherwise only `source.includeSearchPaths` is used.
    static func hasChanges(
        for source: ShaderSource,
        version: Int,
        includeSearchPaths: [ShaderSource.IncludeSearchPath]? = nil
    ) -> Set<ShaderStage> {
        changedStages(for: source, stages: source.stages, version: version, includeSearchPaths: includeSearchPaths)
    }

    static func hasChanges(
        for source: ShaderSource,
        stage: ShaderStage,
        version: Int,
        includeSearchPaths: [ShaderSource.IncludeSearchPath]? = nil
    ) -> Bool {
        changedStages(for: source, stages: [stage], version: version, includeSearchPaths: includeSearchPaths).contains(stage)
    }

    private static func changedStages(
        for source: ShaderSource,
        stages: [ShaderStage],
        version: Int,
        includeSearchPaths: [ShaderSource.IncludeSearchPath]?
    ) -> Set<ShaderStage> {
        guard let fileURL = source.fileURL else {
            return []
        }
        let cacheKey = fileURL.prepareCachePath

        return cachedManifest.withLock { cacheData in
            if cacheData == nil {
                cacheData = self.loadCacheData()
            }

            let cache = cacheData?[cacheKey]
            var changedValues: Set<ShaderStage> = []

            for stage in stages {
                guard let shaderSource = source.getSource(for: stage) else {
                    continue
                }

                let shaderCache = ShaderCache(
                    sourceHashValue: Self.hashValue(of: shaderSource, includeSearchPaths: includeSearchPaths ?? source.includeSearchPaths),
                    headers: source.includeSearchPaths,
                    version: version
                )

                if cache == nil || cache?[stage] != shaderCache {
                    changedValues.insert(stage)
                    cacheData?[cacheKey, default: [:]][stage] = shaderCache

                    Self.removeReflection(for: fileURL, stage: stage)
                }
            }

            if !changedValues.isEmpty, let cacheData {
                self.saveCacheData(cacheData)
            }

            return changedValues
        }
    }

    // MARK: Save/Load SPIRV

    static func getCachedDeviceCompiledShader(
        for source: ShaderSource,
        stage: ShaderStage
    ) -> DeviceCompiledShader? {
        guard let fileURL = source.fileURL else {
            return nil
        }

        let path = fileURL.prepareCachePath

        do {
            let cacheDir = try self.getCacheDirectory()
            let cacheFile =
                cacheDir
                .appending(path: path, directoryHint: .isDirectory)
                .appending(path: "cache-\(stage.rawValue).device-compiled-shader.\(Constants.shaderCacheFileExtension)", directoryHint: .notDirectory)
            guard let data = fileSystem.readFile(at: cacheFile) else {
                return nil
            }
            #if WASM
                return try JSONDecoder().decode(DeviceCompiledShader.self, from: data)
            #else
                return try YAMLDecoder().decode(DeviceCompiledShader.self, from: data)
            #endif
        } catch {
            logger.error("Failed to get cached device compiled shader: \(error)")
            return nil
        }
    }

    static func getCachedShader(
        for source: ShaderSource,
        stage: ShaderStage,
        version: Int,
        entryPoint: String
    ) -> SpirvBinary? {
        guard let fileURL = source.fileURL else {
            return nil
        }

        do {
            let cacheFile = try spirvCacheFile(for: fileURL, stage: stage, version: version)
            guard let data = fileSystem.readFile(at: cacheFile) else {
                return nil
            }
            return SpirvBinary(
                stage: stage,
                data: data,
                language: source.language,
                entryPoint: entryPoint,
                version: version
            )
        } catch {
            logger.error("Failed to get cached device compiled shader: \(error)")
            return nil
        }
    }

    static func save(
        _ spirvBin: SpirvBinary,
        source: ShaderSource,
        stage: ShaderStage,
        version: Int
    ) throws {
        guard let fileURL = source.fileURL else {
            throw CompileError.failed("Source file URL not found")
        }

        let cacheFile = try spirvCacheFile(for: fileURL, stage: stage, version: version)
        let cacheURL = cacheFile.deletingLastPathComponent()

        if !fileSystem.itemExists(at: cacheURL) {
            try fileSystem.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        }

        _ = fileSystem.createFile(at: cacheFile, contents: spirvBin.data)
    }

    static func spirvCacheFile(for fileURL: URL, stage: ShaderStage, version: Int) throws -> URL {
        try getCacheDirectory()
            .appending(path: fileURL.prepareCachePath, directoryHint: .isDirectory)
            .appending(path: "cache-\(stage.rawValue)-\(version).spv", directoryHint: .notDirectory)
    }

    // MARK: - Save/Load Reflection

    static func saveReflection(
        _ reflectionData: ShaderReflectionData,
        for source: ShaderSource,
        stage: ShaderStage
    ) throws {
        guard reflectionData.isEmpty == false else {
            return
        }

        guard let fileURL = source.fileURL else {
            return
        }

        let path = fileURL.prepareCachePath

        let cacheDir = try self.getCacheDirectory()

        let cacheURL =
            cacheDir
            .appending(path: path, directoryHint: .isDirectory)

        if !fileSystem.itemExists(at: cacheURL) {
            try fileSystem.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        }

        let cacheFile =
            cacheURL
            .appending(path: "cache-\(stage.rawValue).\(Constants.shaderCacheFileExtension)", directoryHint: .notDirectory)

        #if WASM
            let stringData = try JSONEncoder().encode(reflectionData)
            _ = fileSystem.createFile(at: cacheFile, contents: stringData)
        #else
            let stringData = try YAMLEncoder().encode(reflectionData)
            _ = fileSystem.createFile(at: cacheFile, contents: Data(stringData.utf8))
        #endif
    }

    static func saveDeviceCompiledShader(
        _ compiledShader: DeviceCompiledShader,
        for source: ShaderSource,
        stage: ShaderStage
    ) throws {
        guard let fileURL = source.fileURL else {
            throw CompileError.failed("Source file URL not found")
        }

        let path = fileURL.prepareCachePath

        let cacheDir = try self.getCacheDirectory()

        let cacheURL =
            cacheDir
            .appending(path: path, directoryHint: .isDirectory)

        if !fileSystem.itemExists(at: cacheURL) {
            try fileSystem.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        }

        let cacheFile =
            cacheURL
            .appending(path: "cache-\(stage.rawValue).device-compiled-shader.\(Constants.shaderCacheFileExtension)", directoryHint: .notDirectory)

        #if WASM
            let stringData = try JSONEncoder().encode(compiledShader)
            _ = fileSystem.createFile(at: cacheFile, contents: stringData)
        #else
            let stringData = try YAMLEncoder().encode(compiledShader)
            _ = fileSystem.createFile(at: cacheFile, contents: Data(stringData.utf8))
        #endif

        let shaderFileForTest =
            cacheURL
            .appending(path: "cache-\(stage.rawValue).shader-source.\(Constants.shaderCacheFileExtension)", directoryHint: .notDirectory)
        _ = fileSystem.createFile(at: shaderFileForTest, contents: Data(compiledShader.source.utf8))
    }

    static func getReflection(for source: ShaderSource, stage: ShaderStage) -> ShaderReflectionData? {
        guard let fileURL = source.fileURL else {
            return nil
        }

        let path = fileURL.prepareCachePath

        do {
            let cacheFile = try self.getCacheDirectory()
                .appending(path: path, directoryHint: .isDirectory)
                .appending(path: "cache-\(stage.rawValue).\(Constants.shaderCacheFileExtension)", directoryHint: .notDirectory)
            guard let data = fileSystem.readFile(at: cacheFile) else {
                return nil
            }
            #if WASM
                return try JSONDecoder().decode(ShaderReflectionData.self, from: data)
            #else
                return try YAMLDecoder().decode(ShaderReflectionData.self, from: data)
            #endif
        } catch {
            logger.error("Failed to get cached reflection: \(error)")
            return nil
        }
    }

    /// Forgets a stage whose changed source failed to compile.
    ///
    /// ``hasChanges(for:stage:version:includeSearchPaths:)`` records the new source hash before compiling. Without
    /// this rollback a failed compile would leave the manifest current while the previous translation stays on disk,
    /// and every later launch would silently reuse that stale translation.
    static func invalidate(for source: ShaderSource, stage: ShaderStage) {
        guard let fileURL = source.fileURL else { return }
        let cacheKey = fileURL.prepareCachePath
        cachedManifest.withLock { cacheData in
            if cacheData == nil { cacheData = self.loadCacheData() }
            guard cacheData?[cacheKey]?[stage] != nil else { return }
            cacheData?[cacheKey]?[stage] = nil
            if let cacheData { self.saveCacheData(cacheData) }
        }
        removeReflection(for: fileURL, stage: stage)
        do {
            let cacheFile = try self.getCacheDirectory()
                .appending(path: cacheKey, directoryHint: .isDirectory)
                .appending(path: "cache-\(stage.rawValue).device-compiled-shader.\(Constants.shaderCacheFileExtension)", directoryHint: .notDirectory)
            if fileSystem.itemExists(at: cacheFile) { try fileSystem.removeItem(at: cacheFile) }
        } catch {
            logger.error("Failed to remove a stale device-compiled shader: \(error)")
        }
    }

    static func removeReflection(for fileURL: URL, stage: ShaderStage) {
        let path = fileURL.prepareCachePath

        do {
            let cacheFile = try self.getCacheDirectory()
                .appending(path: path, directoryHint: .isDirectory)
                .appending(path: "cache-\(stage.rawValue).\(Constants.shaderCacheFileExtension)", directoryHint: .notDirectory)

            guard fileSystem.itemExists(at: cacheFile) else {
                return
            }

            try fileSystem.removeItem(at: cacheFile)
        } catch {
            logger.error("Failed to remove cached reflection: \(error)")
        }
    }

    // MARK: - Private

    private static func loadCacheData() -> Cache {
        self.createCacheDirectoryIfNeeded()

        do {
            let cacheFile = try getCacheFile()
            guard let data = fileSystem.readFile(at: cacheFile) else {
                return [:]
            }

            return try decodeManifest(data)
        } catch {
            logger.warning("Failed to load shader cache manifest: \(error)")
            return [:]
        }
    }

    private static func saveCacheData(_ cacheData: Cache) {
        self.createCacheDirectoryIfNeeded()

        do {
            let cacheFile = try getCacheFile()
            let data = try encodeManifest(cacheData)
            _ = fileSystem.createFile(at: cacheFile, contents: data)
        } catch {
            logger.error("Failed to save shader cache manifest: \(error)")
        }
    }

    static func encodeManifest(_ cacheData: Cache) throws -> Data {
        try JSONEncoder().encode(cacheData)
    }

    static func decodeManifest(_ data: Data) throws -> Cache {
        try JSONDecoder().decode(Cache.self, from: data)
    }

    static func getCacheDirectory() throws -> URL {
        return try self.fileSystem
            .url(for: .cachesDirectory)
            .appendingPathComponent(Constants.cacheDirectoryName)
            .appending(path: Constants.shadersDirectoryName, directoryHint: .isDirectory)
    }

    private static func getCacheFile() throws -> URL {
        try self.getCacheDirectory().appending(path: Constants.shaderCacheFileName, directoryHint: .notDirectory)
    }

    private static func createCacheDirectoryIfNeeded() {
        do {
            let cacheDir = try getCacheDirectory()

            if fileSystem.itemExists(at: cacheDir) {
                return
            }

            return try fileSystem.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } catch {
            fatalError("[ShaderCache] \(error)")
        }
    }

    enum Constants {
        static let cacheDirectoryName = "AdaEngine"
        #if os(Android)
        // Native WebGPU consumes SPIR-V directly; keep its device shader cache
        // separate from the previous GLES prototype and other shader profiles.
        static let shadersDirectoryName = "Shaders-Android-WebGPU-v1"
        #else
        static let shadersDirectoryName = "Shaders"
        #endif
        static let shaderCacheFileName = "ShaderCache-v2.json"
        static let shaderCacheFileExtension = "yaml"
        static let separator = "/"
    }

    enum CompileError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(msg):
                return "[ShaderCache] Failed: \(msg)."
            }
        }
    }
}

extension URL {
    var prepareCachePath: String {
        return self.pathComponents.suffix(3).joined(separator: ShaderCache.Constants.separator).replacingOccurrences(of: ".bundle", with: "")
    }
}
