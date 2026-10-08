//
//  EditorHotReloadController.swift
//  AdaEngine
//

@_spi(AdaEngine) import AdaEngine
import Logging

struct EditorHotReloadState: Equatable, Sendable {
    var isEnabled: Bool
    var watchedPathCount: Int
    var lastReloadedPath: String?
    var errorMessage: String?

    static let unavailable = Self(
        isEnabled: false,
        watchedPathCount: 0,
        lastReloadedPath: nil,
        errorMessage: nil
    )

    var toolbarTitle: String {
        if errorMessage != nil {
            return "Hot Reload Failed"
        }

        if !isEnabled {
            return "Hot Reload Off"
        }

        if lastReloadedPath != nil {
            return "Reloaded"
        }

        return "Hot Reload"
    }

    var footerTitle: String {
        if let errorMessage {
            return "Hot Reload: \(errorMessage)"
        }

        if let lastReloadedPath {
            return "Hot Reload: \(lastReloadedPath)"
        }

        if isEnabled {
            return "Hot Reload: \(watchedPathCount) paths"
        }

        return "Hot Reload: off"
    }
}

@MainActor
final class EditorHotReloadController {
    private let project: EditorProjectReference?
    private let fileManager: FileManager
    private let logger = Logger(label: "org.adaengine.editor.hotReload")
    private let onStateChange: @MainActor (EditorHotReloadState) -> Void
    private var watcher: EditorHotReloadWatcher?

    private(set) var state: EditorHotReloadState = .unavailable {
        didSet {
            onStateChange(state)
        }
    }

    init(
        project: EditorProjectReference?,
        fileManager: FileManager = .default,
        onStateChange: @escaping @MainActor (EditorHotReloadState) -> Void
    ) {
        self.project = project
        self.fileManager = fileManager
        self.onStateChange = onStateChange
    }

    deinit {
        watcher?.stop()
    }

    func start() {
        let paths = EditorHotReloadConfiguration.watchPaths(for: project, fileManager: fileManager)
        guard !paths.isEmpty else {
            state = .unavailable
            logger.warning("Editor hot reload is disabled because no watch paths were found.")
            return
        }

        watcher?.stop()
        state = EditorHotReloadState(
            isEnabled: true,
            watchedPathCount: paths.count,
            lastReloadedPath: nil,
            errorMessage: nil
        )

        let watcher = EditorHotReloadWatcher(paths: paths) { [weak self] changedPaths in
            self?.reload(changedPaths: changedPaths)
        }
        self.watcher = watcher

        do {
            try watcher.start()
        } catch {
            self.watcher = nil
            state = EditorHotReloadState(
                isEnabled: false,
                watchedPathCount: paths.count,
                lastReloadedPath: nil,
                errorMessage: error.localizedDescription
            )
            logger.error("Failed to start editor hot reload watcher: \(error)")
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    func reloadManually() {
        reload(changedPaths: [])
    }

    private func reload(changedPaths: [AbsolutePath]) {
        let changedPath =
            changedPaths
            .map(\.pathString)
            .min()
            .map { URL(fileURLWithPath: $0).lastPathComponent }

        state = EditorHotReloadState(
            isEnabled: state.isEnabled,
            watchedPathCount: state.watchedPathCount,
            lastReloadedPath: changedPath ?? "manual",
            errorMessage: nil
        )
        logger.info("Reloaded editor content via hot reload.")
    }
}

enum EditorHotReloadConfiguration {
    static let latency: Double = 0.15
    static let fallbackSourcePath = "Sources"
    static let fallbackAssetsPath = "Assets"

    static func watchPaths(for project: EditorProjectReference?, fileManager: FileManager = .default) -> [AbsolutePath] {
        guard let project else {
            return []
        }

        let projectURL = URL(fileURLWithPath: project.path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let metadata = try? ProjectSystem.loadProject(at: projectURL, fileManager: fileManager)

        return watchedDirectoryURLs(
            forProjectAt: projectURL,
            metadata: metadata,
            fileManager: fileManager
        )
        .compactMap { url in
            try? AbsolutePath(validating: url.path)
        }
    }

    static func watchedDirectoryURLs(forProjectAt projectURL: URL, metadata: AdaProject?, fileManager: FileManager = .default) -> [URL] {
        let relativePaths = [
            metadata?.paths.sources ?? fallbackSourcePath,
            metadata?.paths.assets ?? fallbackAssetsPath,
            ProjectSystem.metadataDirectoryName,
        ]

        var seenPaths = Set<String>()
        return relativePaths.compactMap { relativePath in
            guard !relativePath.isEmpty else {
                return nil
            }

            let url =
                projectURL
                .appendingPathComponent(relativePath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard isDirectory(at: url, fileManager: fileManager) else {
                return nil
            }

            guard seenPaths.insert(url.path).inserted else {
                return nil
            }

            return url
        }
    }

    private static func isDirectory(at url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
    }
}

private final class EditorHotReloadWatcher: @unchecked Sendable {
    private var watcher: FileWatcher?

    init(
        paths: [AbsolutePath],
        latency: Double = EditorHotReloadConfiguration.latency,
        onChange: @escaping @MainActor @Sendable ([AbsolutePath]) -> Void
    ) {
        self.watcher = FileWatcher(paths: paths, latency: latency) { changedPaths in
            Task { @MainActor in
                onChange(changedPaths)
            }
        }
    }

    deinit {
        stop()
    }

    func start() throws {
        try watcher?.start()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }
}
