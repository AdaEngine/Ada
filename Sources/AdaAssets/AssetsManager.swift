//
//  AssetsManager.swift
//  AdaEngine
//
//  Created by v.prusakov on 6/19/22.
//

@_spi(Internal) import AdaApp
import AdaECS
import AdaUtils
import Foundation
import Logging
import Synchronization
import Tracing

#if WASM && canImport(JavaScriptFoundationCompat) && canImport(JavaScriptKit)
import JavaScriptFoundationCompat
import JavaScriptEventLoop
import JavaScriptKit
#endif

public enum AssetError: LocalizedError {
    case notExistAtPath(String)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .notExistAtPath(let path):
            return "Asset not exists at path: \(path)"
        case .message(let message):
            return message
        }
    }
}

// TODO: In the future, we should compile assets into binary
// TODO: Remove static convenience APIs

/// Manager using for loading and saving assets in file system.
/// Each asset loaded from manager stored in memory cache.
/// If asset was loaded to memory, you recive reference to this resource.
public struct AssetsManager: Resource {

    public struct CachedAssetInfo: Sendable, Hashable {
        public let assetPath: String
        public let assetName: String
        public let typeName: String
        public let isLoaded: Bool
        public let handleCount: Int
        public let assetID: String?

        public init(
            assetPath: String,
            assetName: String,
            typeName: String,
            isLoaded: Bool,
            handleCount: Int,
            assetID: String?
        ) {
            self.assetPath = assetPath
            self.assetName = assetName
            self.typeName = typeName
            self.isLoaded = isLoaded
            self.handleCount = handleCount
            self.assetID = assetID
        }
    }

    private static let logger = Logger(label: "org.adaengine.AssetsManager")

    private static let resKeyWord = "@res://"
    nonisolated(unsafe) private static var registredAssetTypes: [String: any Asset.Type] = [:]

    @AssetActor
    private static var defaultScopeState = AssetsScopeState()

    @AssetActor
    private static var scopeStates: [UUID: AssetsScopeState] = [:]

    private static let scopeConfigurations = Mutex(AssetsScopeConfigurations())

    static var projectDirectories: ProjectDirectories! {
        currentProjectDirectories
    }

    // MARK: - LOADING -

    /// Load a resource. We use `@res://` prefix to link to assets folder.
    ///
    /// ```swift
    /// let texture = try await AssetsManager.load("@res://armor.png") as Texture2D
    ///
    /// // == or ==
    ///
    /// let texture: Texture2D = try await AssetsManager.load("@res://armor.png")
    /// ```
    /// - Parameter path: Path to the resource.
    /// - Returns: Instance of resource.
    @AssetActor
    public static func load<A: Asset>(
        _ type: A.Type,
        at path: String,
        handleChanges: Bool = false
    ) async throws -> AssetHandle<A> {
        let span = AdaTrace.startSpan(lazyName: "Assets.load.\(String(reflecting: A.self))")
        defer {
            span.end()
        }
        if let cachedAsset = self.getHandlingResource(path: path, resourceType: A.self)?.value as? AssetHandle<A> {
            return cachedAsset
        }

        let processedPath = self.processPath(path)

        let hasFileExt = !processedPath.url.pathExtension.isEmpty
        
        if !hasFileExt {
            throw AssetError.notExistAtPath(processedPath.url.path)
        }
        
        if shouldCheckAssetFileExistence {
            guard FileSystem.current.itemExists(at: processedPath.url) else {
                throw AssetError.notExistAtPath(processedPath.url.path)
            }
        }
        
        if handleChanges {
            self.scopeState.storage.hotReloadingAssets[path, default: []].insert(
                HotReloadingAsset(
                    path: processedPath,
                    resource: A.self,
                    needsUpdate: false
                )
            )

            self.updateFileWatcher()
        }
        
        let resource: A = try await self.load(from: processedPath, originalPath: path, bundle: nil)
        let handle = AssetHandle(resource)
        self.scopeState.storage.loadedAssets[path, default: []].insert(WeakBox(handle))

        return handle
    }
    
    /// Load a resource with block current thread and saving it to memory cache.
    /// It may be useful to load resource without concurrent context.
    ///
    /// ```swift
    /// let texture = try AssetsManager.loadSync("@res://armor.png") as Texture2D
    ///
    /// // == or ==
    ///
    /// let texture: Texture2D = try AssetsManager.loadSync("@res://armor.png")
    /// ```
    /// - Parameter path: Path to the resource.
    /// - Returns: Instance of resource.
    #if WASM
    @available(*, unavailable, message: "AssetsManager.loadSync is unavailable on WebAssembly. Use AssetsManager.load(_:at:) instead.")
    public static func loadSync<R: Asset>(
        _ type: R.Type,
        at path: String
    ) throws -> AssetHandle<R> {
        throw AssetError.message("AssetsManager.loadSync is unavailable on WebAssembly. Use AssetsManager.load(_:at:) instead.")
    }
    #else
    public static func loadSync<R: Asset>(
        _ type: R.Type,
        at path: String
    ) throws -> AssetHandle<R> {
        let scopeID = AppWorldsExecutionContext.currentID
        let task = UnsafeTask<AssetHandle<R>> {
            try await AppWorldsExecutionContext.$currentID.withValue(scopeID) {
                try await load(type, at: path)
            }
        }

        return try task.get()
    }
    #endif

    /// Load a resource and saving it to memory cache
    ///
    /// ```swift
    /// let texture = try await AssetsManager.load("Assets/armor.png", from: Bundle.module) as Texture2D
    ///
    /// // == or ==
    ///
    /// let texture: Texture2D = try await AssetsManager.load("Assets/armor.png", from: Bundle.module)
    /// ```
    /// - Parameter path: Path to the resource.
    /// - Parameter bundle: Bundle where we search our resources
    /// - Returns: Instance of resource.
    @AssetActor
    public static func load<A: Asset>(
        _ type: A.Type,
        at path: String,
        from bundle: Bundle,
        handleChanges: Bool = false
    ) async throws -> AssetHandle<A> {
        let span = AdaTrace.startSpan(lazyName: "Assets.load.\(String(reflecting: A.self))")
        defer {
            span.end()
        }
        if let cachedAsset = self.getHandlingResource(path: path, resourceType: A.self)?.value
            as? AssetHandle<A>
        {
            return cachedAsset
        }

        let processedPath = self.processPath(path)
        guard
            let uri = bundle.url(forResource: processedPath.url.relativeString, withExtension: nil),
            !shouldCheckAssetFileExistence || FileSystem.current.itemExists(at: uri)
        else {
            throw AssetError.notExistAtPath(processedPath.url.relativeString)
        }

        let resource: A = try await self.load(
            from: Path(url: uri, query: processedPath.query),
            originalPath: path,
            bundle: bundle
        )
        let handle = AssetHandle(resource)
        self.scopeState.storage.loadedAssets[path, default: []].insert(WeakBox(handle))

        return handle
    }

    /// Load a resource with block current thread and saving it to memory cache.
    /// It may be useful to load resource without concurrent context.
    ///
    /// ```swift
    /// let texture = try AssetsManager.loadSync("Assets/armor.png", from: Bundle.module) as Texture2D
    ///
    /// // == or ==
    ///
    /// let texture: Texture2D = try AssetsManager.loadSync("Assets/armor.png", from: Bundle.module)
    /// ```
    /// - Parameter path: Path to the resource.
    /// - Parameter bundle: Bundle where we search our resources
    /// - Returns: Instance of resource.
    #if WASM
    @available(*, unavailable, message: "AssetsManager.loadSync is unavailable on WebAssembly. Use AssetsManager.load(_:at:from:) instead.")
    public static func loadSync<R: Asset>(
        _ type: R.Type,
        at path: String,
        from bundle: Bundle
    ) throws -> AssetHandle<R> {
        throw AssetError.message("AssetsManager.loadSync is unavailable on WebAssembly. Use AssetsManager.load(_:at:from:) instead.")
    }
    #else
    public static func loadSync<R: Asset>(
        _ type: R.Type,
        at path: String,
        from bundle: Bundle
    ) throws -> AssetHandle<R> {
        let scopeID = AppWorldsExecutionContext.currentID
        let task = UnsafeTask<AssetHandle<R>> {
            try await AppWorldsExecutionContext.$currentID.withValue(scopeID) {
                try await load(type, at: path, from: bundle)
            }
        }

        return try task.get()
    }
    #endif

    /// Load resource in background and save it to the memory.
    public static func loadAsync<R: Asset>(
        _ resourceType: R.Type,
        at path: String,
        completion: @escaping @Sendable (Result<AssetHandle<R>, Error>) -> Void
    ) {
        Task(priority: .background) {
            do {
                let resource = try await self.load(resourceType, at: path)
                completion(.success(resource))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - SAVING -

    // FIXME: Use binary format for specific resource types

    /// Save resource at path.
    @AssetActor
    public static func save<R: Asset>(
        _ asset: R,
        at path: String,
        name: String
    ) async throws {
        try await AdaTrace.span("Assets.save.\(String(reflecting: R.self))") {
            let fileSystem = FileSystem.current
            var processedPath = self.processPath(path)

            processedPath.url.append(path: name)

            if processedPath.url.pathExtension.isEmpty {
                processedPath.url.appendPathExtension(R.extensions().first ?? "")
            }

            let meta = AssetMeta(filePath: processedPath.url, queryParams: processedPath.query)
            let defaultEncoder = TextAssetEncoder(meta: meta)
            try await asset.encodeContents(with: defaultEncoder)

            let intermediateDirs = processedPath.url.deletingLastPathComponent()

            if !fileSystem.itemExists(at: intermediateDirs) {
                try fileSystem.createDirectory(
                    at: intermediateDirs, withIntermediateDirectories: true)
            }

            if fileSystem.itemExists(at: processedPath.url) {
                try fileSystem.removeItem(at: processedPath.url)
            }

            guard let encodedData = defaultEncoder.encodedData else {
                throw AssetError.message("Can't get encoded data from resource.")
            }

            if !FileSystem.current.createFile(at: processedPath.url, contents: encodedData) {
                throw AssetError.message(
                    "Can't create file at path \(processedPath.url.absoluteString)")
            }
        }
    }

    // MARK: - UNLOADING -

    /// Unload specific resource type from memory.
    @AssetActor
    public static func unload<R: Asset>(_ res: R.Type, at path: String) {
        let loadedAssetIndex = self.scopeState.storage.loadedAssets[path, default: []].firstIndex(where: {
            $0.value is AssetHandle<R>
        })
        if let loadedAssetIndex {
            self.scopeState.storage.loadedAssets[path]?.remove(at: loadedAssetIndex)
        }
        self.scopeState.storage.hotReloadingAssets[path] = nil
        self.updateFileWatcher()
    }

    // MARK: - Public methods

    public static func getAssetType(for typeName: String) -> (any Asset.Type)? {
        return unsafe registredAssetTypes[typeName]
    }

    public static func registerAssetType<T: Asset>(_ type: T.Type) {
        Task { @AssetActor in
            unsafe registredAssetTypes[String(reflecting: type)] = T.self
        }
    }

    public static func registeredAssetTypes() -> [String: any Asset.Type] {
        unsafe registredAssetTypes
    }

    @AssetActor
    public static func cachedAssets() -> [CachedAssetInfo] {
        scopeState.storage.loadedAssets.flatMap { path, handles in
            let grouped = Dictionary(grouping: handles.compactMap { $0.value as? AnyAssetHandleInfo }) {
                $0.assetTypeName
            }

            return grouped.map { typeName, typedHandles in
                let first = typedHandles[0]
                return CachedAssetInfo(
                    assetPath: path,
                    assetName: first.assetMetaInfo?.assetName ?? URL(fileURLWithPath: path).lastPathComponent,
                    typeName: typeName,
                    isLoaded: typedHandles.contains(where: \.isLoaded),
                    handleCount: typedHandles.count,
                    assetID: first.assetMetaInfo.map { String($0.assetId.id) }
                )
            }
        }
        .sorted {
            if $0.assetPath == $1.assetPath {
                return $0.typeName < $1.typeName
            }
            return $0.assetPath < $1.assetPath
        }
    }

    /// Set the root folder of all resources and remove all cached items.
    @AssetActor
    public static func setAssetDirectory(_ url: URL) throws {
        if !FileSystem.current.itemExists(at: url) {
            try FileSystem.current.createDirectory(at: url, withIntermediateDirectories: true)
        }

        setProjectDirectories(
            ProjectDirectories(
                source: url.deletingLastPathComponent(),
                assetsDirectory: url
            ),
            scopeID: AppWorldsExecutionContext.currentID
        )
        self.scopeState.storage.loadedAssets.removeAll()
    }

    public static func resolveProjectDirectories(
        filePath: StaticString,
        assetDirectoryNames: [String] = ["Assets", "Resources"]
    ) throws -> ProjectDirectories {
        for name in assetDirectoryNames {
            if let found = URL.findProjectDirectories(from: filePath, for: name) {
                return found
            }
        }

        throw AssetError.message("Missing package directory")
    }

    // MARK: - Internal

    // TODO: (Vlad) where we should call this method in embeddable view?
    // TODO: (Vlad) We must set current dev path to the asset manager
    @_spi(AdaEngine)
    public static func initialize(
        filePath: StaticString,
        assetBundleResourceURL: URL? = nil,
        scopeID: UUID? = AppWorldsExecutionContext.currentID
    ) throws {
        if let resources = assetBundleResourceURL {
            setProjectDirectories(
                ProjectDirectories(
                    source: resources.deletingLastPathComponent(),
                    assetsDirectory: resources
                ),
                scopeID: scopeID
            )
            return
        }

        #if WASM
        let resources = URL(string: "Assets")!
        setProjectDirectories(
            ProjectDirectories(
                source: URL(string: ".")!,
                assetsDirectory: resources
            ),
            scopeID: scopeID
        )
        #else
        let projectDirectories = try resolveProjectDirectories(filePath: filePath)

        #if DEBUG
            setProjectDirectories(projectDirectories, scopeID: scopeID)
        #else
            let fileSystem = FileSystem.current
            let resources = projectDirectories.assetsDirectory

            if !fileSystem.itemExists(at: resources) {
                try fileSystem.createDirectory(at: resources, withIntermediateDirectories: true)
            }

            setProjectDirectories(projectDirectories, scopeID: scopeID)
        #endif
        #endif
    }

    @_spi(AdaEngine)
    @AssetActor
    public static func processResources() async throws {
        for (path, assets) in self.scopeState.storage.hotReloadingAssets {
            for asset in assets where asset.needsUpdate {
                guard let loadedAssets = self.scopeState.storage.loadedAssets[path] else {
                    logger.error("Resource \(asset.resource) is not found")
                    self.scopeState.storage.hotReloadingAssets[path] = nil
                    continue
                }

                await process(loadedAssets: loadedAssets, at: path, asset: asset)
            }
        }
    }

    /// Releases cache and hot-reload state owned by a finished app-world session.
    @_spi(Internal)
    @AssetActor
    public static func destroyScope(_ scopeID: UUID) {
        if let state = scopeStates.removeValue(forKey: scopeID) {
            state.fileWatcher?.stop()
        }
        scopeConfigurations.withLock { configurations in
            configurations.directoriesByScope[scopeID] = nil
        }
    }

    static func withScope<Result>(
        _ scopeID: UUID,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await AppWorldsExecutionContext.$currentID.withValue(scopeID, operation: operation)
    }

    @AssetActor
    private static func process(
        loadedAssets: Set<WeakBox<AnyObject>>,
        at path: String,
        asset: AssetsManager.HotReloadingAsset
    ) async {
        for oldResources in loadedAssets {
            guard let oldResource = oldResources.value as? AnyAssetHandle else {
                continue
            }

            defer {
                var asset = asset
                asset.needsUpdate = false
                self.scopeState.storage.hotReloadingAssets[path]?.insert(asset)
            }

            do {
                try await self.loadAndUpdateInternal(
                    assetType: asset.resource,
                    oldResource: oldResource,
                    from: asset.path,
                    originalPath: asset.path.url.path
                )
            } catch {
                logger.error(
                    "Error updating hot reloading asset \(asset.resource) at path \(asset.path.url.path): \(error)"
                )
            }
        }
    }

    // MARK: - Private

    @AssetActor
    private static func updateHotReloadingAssets() {
        let state = self.scopeState
        do {
            if state.isHotReloadingEnabled {
                try state.fileWatcher?.start()
            } else {
                state.fileWatcher?.stop()
            }
        } catch {
            logger.error("Error updating hot reloading assets: \(error)")
        }
    }

    @AssetActor
    private static func loadAndUpdateInternal(
        assetType: any Asset.Type,
        oldResource: any AnyAssetHandle,
        from path: Path,
        originalPath: String
    ) async throws {
        let data = try await self.readData(from: path)
        let meta = AssetMeta(filePath: path.url, queryParams: path.query)
        let decoder = TextAssetDecoder(meta: meta, data: data)
        try await assetType.loadAndUpdateInternal(from: decoder, oldResource: oldResource)
    }

    @AssetActor
    private static func load<A: Asset>(from path: Path, originalPath: String, bundle: Bundle?)
        async throws -> A
    {
        let data = try await self.readData(from: path)

        let meta = AssetMeta(filePath: path.url, queryParams: path.query)
        let decoder = TextAssetDecoder(meta: meta, data: data)
        var resource = try await A.init(from: decoder)

        resource.assetMetaInfo = AssetMetaInfo(
            assetId: RID(),
            assetPath: originalPath,
            assetName: path.url.lastPathComponent,
            bundlePath: bundle?.bundleIdentifier
        )

        return resource
    }

    private static func readData(from path: Path) async throws -> Data {
        #if WASM && canImport(JavaScriptFoundationCompat) && canImport(JavaScriptKit)
        let fetchURL = self.browserFetchURL(for: path.url)
        let responseValue: JSValue
        do {
            guard let fetch = JSObject.global.fetch.function else {
                throw AssetError.message("Browser fetch is unavailable")
            }
            guard let fetchPromise = JSPromise.construct(from: fetch(fetchURL)) else {
                throw AssetError.message("Browser fetch did not return a promise for \(fetchURL)")
            }
            responseValue = try await fetchPromise.value
        } catch {
            throw AssetError.message("Browser fetch failed for \(fetchURL): \(error)")
        }

        guard let response = responseValue.object else {
            throw AssetError.message("Browser fetch returned an invalid response for \(fetchURL)")
        }
        guard response.ok.boolean == true else {
            throw AssetError.notExistAtPath(fetchURL)
        }

        do {
            guard let arrayBufferValue = response.arrayBuffer?() else {
                throw AssetError.message("Browser response arrayBuffer is unavailable for \(fetchURL)")
            }
            guard let arrayBufferPromise = JSPromise.construct(from: arrayBufferValue) else {
                throw AssetError.message("Browser response did not return an ArrayBuffer promise for \(fetchURL)")
            }
            let arrayBuffer = try await arrayBufferPromise.value
            guard let uint8ArrayConstructor = JSObject.global.Uint8Array.function else {
                throw AssetError.message("Browser Uint8Array constructor is unavailable")
            }
            let uint8Array = uint8ArrayConstructor.new(arrayBuffer)
            guard let data = Data.construct(from: .object(uint8Array)) else {
                throw AssetError.message("Browser response could not be converted to Data for \(fetchURL)")
            }
            return data
        } catch {
            throw AssetError.message("Browser response read failed for \(fetchURL): \(error)")
        }
        #else
        guard let data = FileSystem.current.readFile(at: path.url) else {
            throw AssetError.notExistAtPath(path.url.path)
        }
        return data
        #endif
    }

    #if WASM && canImport(JavaScriptFoundationCompat) && canImport(JavaScriptKit)
    private static func browserFetchURL(for url: URL) -> String {
        guard url.isFileURL else {
            return url.relativeString
        }

        let allowedCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        let relativePath = url.pathComponents
            .filter { $0 != "/" }
            .map { component in
                component.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? component
            }
            .joined(separator: "/")

        return "./\(relativePath)"
    }
    #endif

    private static var shouldCheckAssetFileExistence: Bool {
        #if WASM && canImport(JavaScriptKit)
        false
        #else
        true
        #endif
    }

    private static var currentProjectDirectories: ProjectDirectories? {
        let scopeID = AppWorldsExecutionContext.currentID
        return scopeConfigurations.withLock { configurations in
            guard let scopeID else {
                return configurations.defaultDirectories
            }
            return configurations.directoriesByScope[scopeID]
        }
    }

    private static func setProjectDirectories(
        _ projectDirectories: ProjectDirectories,
        scopeID: UUID?
    ) {
        scopeConfigurations.withLock { configurations in
            if let scopeID {
                configurations.directoriesByScope[scopeID] = projectDirectories
            } else {
                configurations.defaultDirectories = projectDirectories
            }
        }
    }

    @AssetActor
    private static var scopeState: AssetsScopeState {
        guard let scopeID = AppWorldsExecutionContext.currentID else {
            return defaultScopeState
        }
        if let state = scopeStates[scopeID] {
            return state
        }
        let state = AssetsScopeState()
        scopeStates[scopeID] = state
        return state
    }
}

extension AssetsManager {
    struct Path: Sendable, Hashable {
        var url: URL
        let query: [AssetQuery]
    }

    static func getFilePath(from meta: AssetMetaInfo) -> Path {
        let processedPath = self.processPath(meta.assetPath)
        if let bundlePath = meta.bundlePath, let bundle = Bundle(path: bundlePath) {
            if let uri = bundle.url(
                forResource: processedPath.url.relativeString, withExtension: nil)
            {
                return Path(url: uri, query: processedPath.query)
            }
        }

        return processedPath
    }

    @_spi(AdaEngine)
    public static func resolveAssetURL(at path: String) -> URL {
        self.processPath(path).url
    }

    @AssetActor
    static func isAssetExistsInCache<A: Asset>(_ type: A.Type, at path: String) -> Bool {
        self.getHandlingResource(path: path, resourceType: type)?.value != nil
    }
}

extension AssetsManager {

    @AssetActor
    private static func getHandlingResource<A: Asset>(
        path: String,
        resourceType: A.Type
    ) -> WeakBox<AnyObject>? {
        self.scopeState.storage.loadedAssets[path]?.first(where: { $0.value is AssetHandle<A> })
    }

    /// Replace tag `@res://` to relative path or create url from given path.
    private static func processPath(_ path: String) -> Path {
        var path = path
        var url: URL

        if path.hasPrefix(self.resKeyWord) && !path.hasPrefix("file://") {
            path.removeFirst(self.resKeyWord.count)
            let resourceDirectory = currentProjectDirectories?.assetsDirectory
                ?? URL(fileURLWithPath: ".", isDirectory: true)
            url = resourceDirectory.appendingPathComponent(path)
        } else {
            url = path.hasPrefix("file://") ? URL(string: path)! : URL(fileURLWithPath: path)
        }

        let splitComponents = url.lastPathComponent.split(separator: "#")

        var query = [AssetQuery]()

        if !splitComponents.isEmpty {
            query = Self.fetchQuery(from: String(splitComponents.last!))
            url.deleteLastPathComponent()
            url.appendPathComponent(String(splitComponents.first!))
        }

        return Path(url: url, query: query)
    }

    @AssetActor
    private static func updateFileWatcher() {
        let state = self.scopeState
        if state.storage.hotReloadingAssets.values.isEmpty {
            return
        }

        // Collect unique directory paths - on Windows, FileWatcher needs directories, not files
        var watchedDirectories = Set<String>()
        for (_, asset) in state.storage.hotReloadingAssets {
            guard let firstAsset = asset.first else {
                continue
            }
            // Get directory path - on Windows, FileWatcher needs directories, not files
            let directoryURL = firstAsset.path.url.deletingLastPathComponent()
                .resolvingSymlinksInPath()
            let directoryPath = directoryURL.path

            // Ensure directory exists before watching
            if FileSystem.current.itemExists(at: directoryURL) {
                watchedDirectories.insert(directoryPath)
            } else {
                logger.warning("Directory does not exist for watching: \(directoryPath)")
            }
        }

        guard !watchedDirectories.isEmpty else {
            logger.warning("No valid directories to watch")
            return
        }

        let watchedPaths = Array(watchedDirectories).compactMap {
            try? AbsolutePath(validating: $0)
        }
        guard !watchedPaths.isEmpty else {
            logger.warning("No valid absolute paths to watch")
            return
        }

        if state.fileWatcher?.paths == watchedPaths {
            return
        }

        let scopeID = AppWorldsExecutionContext.currentID
        state.fileWatcher = FileWatcher(
            paths: watchedPaths,
            latency: 0.1,
            block: { fsPaths in
                // Dispatch to AssetActor to avoid race conditions
                Task { @AssetActor in
                    AppWorldsExecutionContext.$currentID.withValue(scopeID) {
                        let state = self.scopeState
                        for path in fsPaths {
                            // Resolve symlinks in incoming paths as well for consistent matching
                            let resolvedDirectoryPath = URL(fileURLWithPath: path.pathString)
                                .resolvingSymlinksInPath().path

                            // Find all assets in this directory and mark them for update
                            for (assetPath, assets) in state.storage.hotReloadingAssets {
                                guard let firstAsset = assets.first else {
                                    continue
                                }
                                let assetDirectoryPath = firstAsset.path.url.deletingLastPathComponent()
                                    .resolvingSymlinksInPath().path

                                // Check if this asset is in the changed directory
                                if assetDirectoryPath == resolvedDirectoryPath {
                                    for var asset in assets {
                                        asset.needsUpdate = true
                                        state.storage.hotReloadingAssets[assetPath]?.insert(asset)
                                    }
                                    logger.info("Marked asset at path \(assetPath) for hot reload.")
                                }
                            }
                        }
                    }
                }
            }
        )

        do {
            if state.isHotReloadingEnabled {
                try state.fileWatcher?.start()
                logger.info("Started file watcher for paths: \(watchedPaths)")
            }
        } catch {
            logger.error("Error updating file watcher: \(error)")
        }
    }

    private static func fetchQuery(from string: String) -> [AssetQuery] {
        let quieries = string.split(separator: "&")
        return quieries.map { query in
            let pairs = query.split(separator: "=")
            if pairs.count == 2 {
                return AssetQuery(name: String(pairs[0]), value: String(pairs[1]))
            } else {
                return AssetQuery(name: String(pairs[0]), value: nil)
            }
        }
    }
}

extension AssetsManager {
    struct AssetsStorage: Sendable {
        var loadedAssets: [String: Set<WeakBox<AnyObject>>] = [:]
        var hotReloadingAssets: [String: Set<HotReloadingAsset>] = [:]
    }

    struct HotReloadingAsset: Sendable, Hashable {
        var path: Path
        var resource: any Asset.Type
        var needsUpdate: Bool = false

        static func == (lhs: AssetsManager.HotReloadingAsset, rhs: AssetsManager.HotReloadingAsset)
            -> Bool
        {
            lhs.path == rhs.path
                && ObjectIdentifier(lhs.resource) == ObjectIdentifier(rhs.resource)
                && lhs.needsUpdate == rhs.needsUpdate
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(self.path)
            hasher.combine(ObjectIdentifier(self.resource))
            hasher.combine(self.needsUpdate)
        }
    }
}

private struct AssetsScopeConfigurations: Sendable {
    var defaultDirectories: ProjectDirectories?
    var directoriesByScope: [UUID: ProjectDirectories] = [:]
}

private final class AssetsScopeState {
    var storage = AssetsManager.AssetsStorage()
    var fileWatcher: FileWatcher?
    var isHotReloadingEnabled = true
}

/// Actor for loading and saving resources.
@globalActor
public actor AssetActor {
    public static let shared = AssetActor()
}

extension Asset {
    @AssetActor
    fileprivate static func loadAndUpdateInternal(
        from asset: any AssetDecoder,
        oldResource: any AnyAssetHandle
    ) async throws {
        let resource = try await Self.init(from: asset)
        try oldResource.update(resource)
    }
}

extension URL {
    fileprivate static func findProjectDirectories(
        from file: StaticString,
        for name: String
    ) -> ProjectDirectories? {
        var currentURL = URL(filePath: file.description)
        var assetDirectory: URL?

        while currentURL.path != "/" {
            currentURL = currentURL.deletingLastPathComponent()
            let packageURL = currentURL.appending(path: "Package.swift")

            if FileManager.default.fileExists(atPath: packageURL.path) {
                return ProjectDirectories(
                    source: packageURL.deletingLastPathComponent(),
                    assetsDirectory: assetDirectory ?? currentURL.appending(path: name)
                )
            }

            let assetsDirectory = currentURL.appending(path: name)
            if FileManager.default.fileExists(atPath: assetsDirectory.path) {
                assetDirectory = assetsDirectory
            }
        }

        return nil
    }
}

public struct ProjectDirectories: Sendable {
    /// Source directory is a directory where we store all source code for the project.
    public let source: URL

    /// Assets directory is a directory where we store all assets for the project.
    public let assetsDirectory: URL

    public var packageDirectory: URL {
        source
    }
}
