@_spi(AdaEngine) import AdaEngine
import Foundation

/// Coalesces filesystem events before refreshing the observable project tree.
@MainActor
final class EditorProjectFileWatcher {
    private let root: URL
    private let onChange: @MainActor ([String]) -> Void
    private var watcher: FileWatcher?
    private var pendingTask: Task<Void, Never>?
    private var pendingPaths = Set<String>()
    private var generation = UUID()
    private var rootAliases: Set<String> = []

    init(root: URL, onChange: @escaping @MainActor ([String]) -> Void) {
        self.root = root.resolvingSymlinksInPath()
        self.onChange = onChange
    }

    deinit {
        pendingTask?.cancel()
        watcher?.stop()
    }

    func start() throws {
        guard watcher == nil else {
            return
        }
        let token = generation
        let watcher = FileWatcher(paths: [try AbsolutePath(validating: root.path)], latency: 0.15) { [weak self] paths in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.watcher != nil else {
                    return
                }
                self.enqueue(paths)
            }
        }
        self.watcher = watcher
        do {
            try watcher.start()
        } catch {
            self.watcher = nil
            throw error
        }
    }

    func stop() {
        generation = UUID()
        pendingTask?.cancel()
        pendingTask = nil
        pendingPaths.removeAll()
        watcher?.stop()
        watcher = nil
    }

    private func relativePath(for path: AbsolutePath) -> String? {
        let absolute = path.pathString
        for alias in rootAliases.union([root.path]) {
            if absolute == alias {
                return ""
            }
            if absolute.hasPrefix(alias + "/") {
                return String(absolute.dropFirst(alias.count + 1))
            }
        }
        // FSEvents uses physical paths such as /private/var; Foundation may use
        // /var. Resolve the surviving root, never a file that was just deleted.
        var ancestor = URL(fileURLWithPath: absolute)
        while ancestor.path != "/" {
            if ancestor.resolvingSymlinksInPath().path == root.path {
                let alias = ancestor.path
                rootAliases.insert(alias)
                return absolute == alias ? "" : String(absolute.dropFirst(alias.count + 1))
            }
            ancestor.deleteLastPathComponent()
        }
        return nil
    }

    private func enqueue(_ paths: [AbsolutePath]) {
        let ignored: Set<String> = [".git", ".build", ".swiftpm", ".ada", "DerivedData", ".DS_Store"]
        let relativePaths = paths.compactMap { path -> String? in
            guard let relative = relativePath(for: path) else {
                return nil
            }
            guard !relative.split(separator: "/").contains(where: { ignored.contains(String($0)) }) else {
                return nil
            }
            return relative
        }
        guard !relativePaths.isEmpty else {
            return
        }
        pendingPaths.formUnion(relativePaths)
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch { return }
            guard let self else {
                return
            }
            let changed = self.pendingPaths.sorted()
            self.pendingPaths.removeAll()
            self.pendingTask = nil
            self.onChange(changed)
        }
    }
}

extension EditorViewModel {
    func startProjectFileWatching() {
        // The engine's filesystem event backend is recursive on macOS.
        #if os(macOS)
            guard projectFileWatcher == nil, let projectURL else {
                return
            }
            let watcher = EditorProjectFileWatcher(root: projectURL) { [weak self] paths in
                guard let self else {
                    return
                }
                self.refreshProjectFiles(logsRefresh: false)
                self.refreshSourceControl()
                for path in paths where !path.isEmpty {
                    self.reloadOpenProjectFile(relativePath: path)
                }
            }
            do {
                try watcher.start()
                projectFileWatcher = watcher
                refreshProjectFiles(logsRefresh: false)
            } catch {
                appendOutput("Unable to watch project files: \(error.localizedDescription)")
            }
        #endif
    }

    func stopProjectFileWatching() {
        projectFileWatcher?.stop()
        projectFileWatcher = nil
    }
}
